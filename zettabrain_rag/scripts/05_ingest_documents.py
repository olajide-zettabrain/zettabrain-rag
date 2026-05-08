"""
ZettaBrain — Document Ingestion Utility

Incrementally ingests documents into the ChromaDB vector store.
Skips already-ingested files using MD5 hash tracking.

Usage:
    python 05_ingest_documents.py                        # ingest /mnt/Rag-data (default)
    python 05_ingest_documents.py --folder /mnt/Rag-data/contracts
    python 05_ingest_documents.py --file /mnt/Rag-data/report.pdf
    python 05_ingest_documents.py --stats                # show what's ingested
    python 05_ingest_documents.py --clear                # wipe the vector store
"""

import argparse
import hashlib
import json
import os
import time
from pathlib import Path

from langchain_community.document_loaders import PyPDFLoader, TextLoader, Docx2txtLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma

try:
    from zettabrain_rag.retrieval import rebuild_bm25_index
    _HAS_RETRIEVAL = True
except ImportError:
    _HAS_RETRIEVAL = False

# -------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------
def _load_zettabrain_env() -> dict:
    cfg = {}
    candidates = [
        "/opt/zettabrain/src/zettabrain.env",
        "/zettabrain/src/zettabrain.env",
    ]
    # Windows: %LOCALAPPDATA%\ZettaBrain\zettabrain.env
    local_app = os.environ.get("LOCALAPPDATA")
    if local_app:
        candidates.append(os.path.join(local_app, "ZettaBrain", "zettabrain.env"))
    for p in candidates:
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        cfg[k.strip()] = v.strip().strip('"').strip("'")
            break
    return cfg

_cfg = _load_zettabrain_env()

def _get(key, fallback):
    return os.environ.get(key) or _cfg.get(key) or fallback

def _default_chroma() -> str:
    if os.name == "nt":
        local_app = os.environ.get("LOCALAPPDATA", os.path.expanduser("~\\AppData\\Local"))
        return os.path.join(local_app, "ZettaBrain", "zettabrain_vectorstore")
    return "/opt/zettabrain/src/zettabrain_vectorstore"

def _default_docs() -> str:
    if os.name == "nt":
        return os.path.join(os.path.expanduser("~"), "Documents")
    return "/opt/zettabrain/data"

def _default_hash_cache() -> str:
    if os.name == "nt":
        local_app = os.environ.get("LOCALAPPDATA", os.path.expanduser("~\\AppData\\Local"))
        return os.path.join(local_app, "ZettaBrain", "ingested_files.json")
    return "./ingested_files.json"

DOCS_FOLDER = _get("ZETTABRAIN_DOCS",    _get("RAG_DATA_PATH", _default_docs()))
CHROMA_PATH = _get("ZETTABRAIN_CHROMA",  _default_chroma())
EMBED_MODEL = os.environ.get("ZETTABRAIN_EMBED_MODEL", "nomic-embed-text")
HASH_CACHE  = _default_hash_cache()

SUPPORTED = {".pdf", ".txt", ".docx", ".md"}


# -------------------------------------------------------
# HELPERS
# -------------------------------------------------------
def get_file_hash(filepath: str) -> str:
    with open(filepath, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def load_hash_cache() -> dict:
    if os.path.exists(HASH_CACHE):
        with open(HASH_CACHE) as f:
            return json.load(f)
    return {}


def save_hash_cache(cache: dict):
    with open(HASH_CACHE, "w") as f:
        json.dump(cache, f, indent=2)


def _load_pdf(filepath: str):
    """Try PyMuPDF first (better layout handling), fall back to pypdf."""
    try:
        import fitz  # pymupdf
        docs = []
        pdf = fitz.open(filepath)
        for page_num, page in enumerate(pdf):
            text = page.get_text("text").strip()
            if text:
                from langchain_core.documents import Document
                docs.append(Document(
                    page_content=text,
                    metadata={"source": filepath, "page": page_num}
                ))
        pdf.close()
        if docs:
            return docs
        # PyMuPDF found no text — fall through to pypdf
    except ImportError:
        pass
    except Exception:
        pass

    # Fallback: pypdf
    try:
        return PyPDFLoader(filepath).load()
    except Exception as e:
        print(f"  [WARN] Could not parse PDF {Path(filepath).name}: {e}")
        return []


def load_file(filepath: str):
    ext = Path(filepath).suffix.lower()
    if ext == ".pdf":
        return _load_pdf(filepath)
    elif ext in {".txt", ".md"}:
        return TextLoader(filepath, encoding="utf-8").load()
    elif ext in {".docx", ".doc"}:
        return Docx2txtLoader(filepath).load()
    return []


BATCH_SIZE = 50  # chunks per embedding call


def _adaptive_splitter(filepath: str, docs) -> RecursiveCharacterTextSplitter:
    """Tune chunk size by file type and text density."""
    ext = Path(filepath).suffix.lower()
    if ext == ".pdf":
        size, overlap = 1000, 150
    elif ext in {".docx", ".doc"}:
        size, overlap = 1200, 200
    else:  # .txt, .md
        size, overlap = 800, 100

    # Dense technical text (long sentences) → scale up
    sample = " ".join(d.page_content for d in docs[:5])
    sentences = [s.strip() for s in sample.replace("\n", " ").split(".") if s.strip()]
    if sentences and sum(len(s) for s in sentences) / len(sentences) > 120:
        size    = int(size    * 1.5)
        overlap = int(overlap * 1.5)

    return RecursiveCharacterTextSplitter(
        chunk_size=size,
        chunk_overlap=overlap,
        separators=["\n\n\n", "\n\n", "\n", ". ", " ", ""]
    )


def ingest_file(filepath: str, vectorstore, hash_cache: dict) -> bool:
    """Ingest a single file. Returns True if ingested, False if skipped."""
    filepath = str(Path(filepath).resolve())
    file_hash = get_file_hash(filepath)

    if hash_cache.get(filepath) == file_hash:
        print(f"  [SKIP] {Path(filepath).name} (already ingested)")
        return False

    docs = load_file(filepath)
    if not docs:
        print(f"  [SKIP] {Path(filepath).name} (unsupported or empty)")
        return False

    splitter = _adaptive_splitter(filepath, docs)
    chunks = splitter.split_documents(docs)

    # Drop empty chunks that would cause ChromaDB to reject the batch
    chunks = [c for c in chunks if c.page_content.strip()]

    for chunk in chunks:
        chunk.metadata["source"]   = filepath
        chunk.metadata["filename"] = Path(filepath).name

    # Embed in small batches with retry so one Ollama hiccup doesn't abort the file
    added = 0
    for i in range(0, len(chunks), BATCH_SIZE):
        batch = chunks[i : i + BATCH_SIZE]
        for attempt in range(3):
            try:
                vectorstore.add_documents(batch)
                added += len(batch)
                break
            except Exception as e:
                if attempt == 2:
                    print(f"  [WARN] {Path(filepath).name} batch {i//BATCH_SIZE + 1} failed: {e}")
                else:
                    time.sleep(2 ** attempt)

    if added == 0:
        print(f"  [FAIL] {Path(filepath).name} — no chunks embedded, skipping hash save")
        return False

    hash_cache[filepath] = file_hash
    print(f"  [OK]   {Path(filepath).name} ({added}/{len(chunks)} chunks)")
    return True


# -------------------------------------------------------
# MAIN
# -------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="ZettaBrain Document Ingestion")
    parser.add_argument("--folder", default=DOCS_FOLDER,
                        help=f"Ingest all supported files in a folder (default: {DOCS_FOLDER})")
    parser.add_argument("--file",   default=None, help="Ingest a single file")
    parser.add_argument("--clear",  action="store_true", help="Clear the entire vector store")
    parser.add_argument("--stats",  action="store_true", help="Show vector store statistics")
    args = parser.parse_args()

    ollama_host = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
    embeddings  = OllamaEmbeddings(model=EMBED_MODEL, base_url=ollama_host)
    os.makedirs(CHROMA_PATH, exist_ok=True)
    vectorstore = Chroma(
        persist_directory=CHROMA_PATH,
        embedding_function=embeddings,
        collection_name="zettabrain_docs"
    )

    # ---- Stats ----
    if args.stats:
        count      = vectorstore._collection.count()
        hash_cache = load_hash_cache()
        print(f"\nVector store : {CHROMA_PATH}")
        print(f"Total chunks : {count}")
        print(f"Tracked files: {len(hash_cache)}")
        for fp in sorted(hash_cache):
            print(f"  - {Path(fp).name}")
        print()
        return

    # ---- Clear ----
    if args.clear:
        confirm = input("This will delete ALL ingested documents. Type 'yes' to confirm: ")
        if confirm.lower() == "yes":
            vectorstore._client.delete_collection("zettabrain_docs")
            save_hash_cache({})
            print("Vector store cleared.")
        else:
            print("Cancelled.")
        return

    # ---- Ingest ----
    hash_cache = load_hash_cache()
    ingested   = 0

    if args.file:
        print(f"\nIngesting file: {args.file}")
        if ingest_file(args.file, vectorstore, hash_cache):
            ingested += 1

    else:
        folder = Path(args.folder)
        if not folder.exists():
            print(f"ERROR: Folder not found: {folder}")
            print(f"Check the path exists: ls {DOCS_FOLDER}")
            return

        files = [f for f in folder.rglob("*") if f.suffix.lower() in SUPPORTED]
        print(f"\nFound {len(files)} supported file(s) in {folder}")

        for f in sorted(files):
            if ingest_file(str(f), vectorstore, hash_cache):
                ingested += 1

    save_hash_cache(hash_cache)
    print(f"\nDone. {ingested} new file(s) ingested.")
    print(f"Total chunks in store: {vectorstore._collection.count()}")

    if ingested > 0 and _HAS_RETRIEVAL:
        print("Rebuilding BM25 keyword index...")
        n = rebuild_bm25_index(vectorstore)
        print(f"BM25 index: {n} chunks indexed.")


if __name__ == "__main__":
    main()
