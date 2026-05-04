"""
ZettaBrain Local RAG Pipeline v2
LangChain + Ollama + ChromaDB

Improvements over v1:
- Larger chunk size suited for Wikipedia-style long articles
- MMR retrieval (diversity over pure similarity)
- Smarter prompt that actually uses retrieved context
- Debug mode to inspect what retriever finds
- --rebuild flag to force vector store rebuild
"""

import os
import time
import argparse
from pathlib import Path

from langchain_community.document_loaders import (
    PyPDFLoader,
    TextLoader,
    Docx2txtLoader,
)
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_ollama import OllamaEmbeddings, OllamaLLM
from langchain_chroma import Chroma
from langchain_core.prompts import PromptTemplate

from zettabrain_rag.retrieval import hybrid_retrieve, RAG_PROMPT, format_context

try:
    from tqdm import tqdm
    _HAS_TQDM = True
except ImportError:
    _HAS_TQDM = False


def _elapsed(t0: float) -> str:
    s = time.time() - t0
    return f"{s:.1f}s" if s < 60 else f"{s/60:.1f}m"

# -------------------------------------------------------
# CONFIGURATION
# Priority: env var > zettabrain.env file > hardcoded fallback
# -------------------------------------------------------

def _load_zettabrain_env() -> dict:
    """Load zettabrain.env config file if it exists."""
    cfg = {}
    env_paths = [
        "/opt/zettabrain/src/zettabrain.env",
        "/zettabrain/src/zettabrain.env",
    ]
    for p in env_paths:
        if os.path.exists(p):
            with open(p) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        cfg[k.strip()] = v.strip().strip('"').strip("'")
            break
    return cfg

_cfg = _load_zettabrain_env()

def _get(key: str, fallback: str) -> str:
    """Get config value: env var overrides file which overrides fallback."""
    return os.environ.get(key) or _cfg.get(key) or fallback

DOCS_FOLDER   = _get("ZETTABRAIN_DOCS",        _get("RAG_DATA_PATH", "/opt/zettabrain/data"))
CHROMA_PATH   = _get("ZETTABRAIN_CHROMA",       "/opt/zettabrain/src/zettabrain_vectorstore")
EMBED_MODEL   = _get("ZETTABRAIN_EMBED_MODEL",  "nomic-embed-text")
LLM_MODEL     = _get("ZETTABRAIN_LLM_MODEL",    "llama3.1:8b")
CHUNK_SIZE    = int(_get("ZETTABRAIN_CHUNK_SIZE",    "1500"))
CHUNK_OVERLAP = int(_get("ZETTABRAIN_CHUNK_OVERLAP", "200"))
DEBUG         = False


# -------------------------------------------------------
# 1. LOAD DOCUMENTS
# -------------------------------------------------------
def load_documents(docs_folder: str):
    folder = Path(docs_folder)
    if not folder.exists():
        print(f"ERROR: Folder not found: {docs_folder}")
        print("Check NFS mount: ls /mnt/Rag-data")
        return []

    loaders = []
    for f in folder.rglob("*.pdf"):
        loaders.append(PyPDFLoader(str(f)))
    for f in folder.rglob("*.txt"):
        loaders.append(TextLoader(str(f), encoding="utf-8"))
    for f in folder.rglob("*.docx"):
        loaders.append(Docx2txtLoader(str(f)))

    if not loaders:
        print(f"No supported files found in {docs_folder}")
        return []

    documents = []
    for loader in loaders:
        try:
            docs = loader.load()
            for doc in docs:
                if "source" not in doc.metadata:
                    doc.metadata["source"] = str(
                        getattr(loader, "file_path", "unknown")
                    )
            documents.extend(docs)
            fname = Path(getattr(loader, "file_path", "file")).name
            print(f"  Loaded: {fname} ({len(docs)} pages)")
        except Exception as e:
            print(f"  Warning: Could not load — {e}")

    return documents


# -------------------------------------------------------
# 2. SPLIT INTO CHUNKS
# -------------------------------------------------------
def split_documents(documents):
    splitter = RecursiveCharacterTextSplitter(
        chunk_size=CHUNK_SIZE,
        chunk_overlap=CHUNK_OVERLAP,
        separators=["\n\n\n", "\n\n", "\n", ". ", " ", ""]
    )
    chunks = splitter.split_documents(documents)
    print(f"Total chunks created: {len(chunks)}")
    return chunks


# -------------------------------------------------------
# 3. CREATE / LOAD VECTOR STORE
# -------------------------------------------------------
EMBED_BATCH = 50


def get_vectorstore(chunks=None, force_rebuild=False):
    embeddings = OllamaEmbeddings(model=EMBED_MODEL)

    if os.path.exists(CHROMA_PATH) and not force_rebuild:
        print(f"  Loading existing vector store from: {CHROMA_PATH}")
        vs = Chroma(
            persist_directory=CHROMA_PATH,
            embedding_function=embeddings,
            collection_name="zettabrain_docs"
        )
        count = vs._collection.count()
        if count == 0:
            print("  WARNING: Vector store is empty — forcing rebuild")
            return get_vectorstore(chunks, force_rebuild=True)
        print(f"  Loaded {count} chunks.")
        return vs

    if not chunks:
        raise ValueError("No chunks provided and no existing vector store found.")

    print(f"  Embedding {len(chunks)} chunks with {EMBED_MODEL}...")
    vs = Chroma(
        persist_directory=CHROMA_PATH,
        embedding_function=embeddings,
        collection_name="zettabrain_docs"
    )
    batches = range(0, len(chunks), EMBED_BATCH)
    if _HAS_TQDM:
        batches = tqdm(batches, desc="  Progress", unit="batch",
                       bar_format="{desc}: {percentage:3.0f}%|{bar}| {n}/{total} batches [{elapsed}<{remaining}]")
    for i in batches:
        vs.add_documents(chunks[i : i + EMBED_BATCH])
    print(f"  Vector store saved to: {CHROMA_PATH}")
    return vs


# -------------------------------------------------------
# 4. BUILD LLM
# -------------------------------------------------------
def build_llm():
    return OllamaLLM(model=LLM_MODEL, temperature=0.0, num_predict=1024)


# -------------------------------------------------------
# 5. INTERACTIVE CHAT
# -------------------------------------------------------
def chat(llm, vectorstore):
    print("\n" + "="*60)
    print("ZettaBrain Local RAG v2")
    print("Commands: 'sources' | 'timing' | 'debug on/off' | 'quit'")
    print("="*60 + "\n")

    prompt       = PromptTemplate.from_template(RAG_PROMPT)
    last_sources = []
    debug        = DEBUG
    timing_log   = []   # list of (t_retrieve, t_generate)

    while True:
        try:
            query = input("You: ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nGoodbye.")
            break

        if not query:
            continue

        if query.lower() in ["quit", "exit", "q"]:
            print("Goodbye.")
            break

        if query.lower() == "sources":
            if last_sources:
                print(f"\nRetrieved {len(last_sources)} chunks:\n")
                for i, doc in enumerate(last_sources, 1):
                    src      = Path(doc.metadata.get("source", "unknown")).name
                    page     = doc.metadata.get("page", "")
                    page_str = f" p.{page}" if page else ""
                    print(f"  [{i}] {src}{page_str}")
                    print(f"      {doc.page_content[:200]}\n")
            else:
                print("No previous query yet.")
            print()
            continue

        if query.lower() == "timing":
            if timing_log:
                print(f"\n{'#':>3}  {'Retrieve':>9}  {'Generate':>9}  {'Total':>7}")
                print("─" * 34)
                for idx, (tr, tg) in enumerate(timing_log, 1):
                    marker = " ←" if idx == len(timing_log) else ""
                    print(f"  {idx:>1}  {tr:>8.1f}s  {tg:>8.1f}s  {tr+tg:>6.1f}s{marker}")
                print()
            else:
                print("No queries yet.\n")
            continue

        if query.lower() == "debug on":
            debug = True
            print("Debug mode ON — retrieved chunks shown on every query\n")
            continue

        if query.lower() == "debug off":
            debug = False
            print("Debug mode OFF\n")
            continue

        print("Thinking...\n")

        t_r0         = time.time()
        last_sources = hybrid_retrieve(query, vectorstore)
        t_retrieve   = time.time() - t_r0

        if debug:
            print(f"[DEBUG] {len(last_sources)} chunks retrieved:")
            for i, doc in enumerate(last_sources, 1):
                src = Path(doc.metadata.get("source", "?")).name
                print(f"  [{i}] {src}: {doc.page_content[:150]}")
            print()

        context    = format_context(last_sources)
        t_g0       = time.time()
        answer     = llm.invoke(prompt.format(context=context, question=query))
        t_generate = time.time() - t_g0

        timing_log.append((t_retrieve, t_generate))
        t_total = t_retrieve + t_generate

        # Delta vs previous query
        if len(timing_log) > 1:
            prev_total = sum(timing_log[-2])
            delta      = t_total - prev_total
            sign       = "+" if delta >= 0 else ""
            delta_str  = f"  {sign}{delta:.1f}s vs prev"
        else:
            delta_str = ""

        print(f"Assistant: {answer}\n")
        print(
            f"[{len(last_sources)} chunks • "
            f"retrieve {t_retrieve:.1f}s • "
            f"generate {t_generate:.1f}s • "
            f"total {t_total:.1f}s"
            f"{delta_str} — 'sources' / 'timing' for details]\n"
        )


# -------------------------------------------------------
# MAIN
# -------------------------------------------------------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="ZettaBrain Local RAG v2")
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="Force rebuild the vector store (use after adding new documents)"
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Show retrieved chunks on every query"
    )
    args = parser.parse_args()

    if args.debug:
        DEBUG = True

    print("ZettaBrain Local RAG Pipeline v2")
    print("="*40)

    t_total = time.time()

    t0 = time.time()
    print(f"\n[1/4] Loading documents from {DOCS_FOLDER}...")
    documents = load_documents(DOCS_FOLDER)
    print(f"  → {len(documents)} page(s) loaded in {_elapsed(t0)}")

    if documents:
        t0 = time.time()
        print(f"\n[2/4] Splitting {len(documents)} document(s)...")
        chunks = split_documents(documents)
        print(f"  → {len(chunks)} chunks in {_elapsed(t0)}")

        t0 = time.time()
        print("\n[3/4] Setting up vector store...")
        vectorstore = get_vectorstore(chunks, force_rebuild=args.rebuild)
        print(f"  → Done in {_elapsed(t0)}")
    else:
        t0 = time.time()
        print("\n[2/4] No documents found — loading existing vector store...")
        vectorstore = get_vectorstore()
        print(f"  → Done in {_elapsed(t0)}")

    t0 = time.time()
    print("\n[4/4] Building LLM...")
    llm = build_llm()
    print(f"  → Ready in {_elapsed(t0)}")
    print(f"\nStartup complete in {_elapsed(t_total)}")

    chat(llm, vectorstore)
