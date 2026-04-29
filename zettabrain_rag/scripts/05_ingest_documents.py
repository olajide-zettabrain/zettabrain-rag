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

# -------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------
def _load_zettabrain_env() -> dict:
    cfg = {}
    for p in ["/opt/zettabrain/src/zettabrain.env", "/zettabrain/src/zettabrain.env"]:
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

def _get(key, fallback):
    return os.environ.get(key) or _cfg.get(key) or fallback

DOCS_FOLDER = _get("ZETTABRAIN_DOCS",    _get("RAG_DATA_PATH", "/opt/zettabrain/data"))
CHROMA_PATH = _get("ZETTABRAIN_CHROMA",  "/opt/zettabrain/src/zettabrain_vectorstore")
EMBED_MODEL = os.environ.get("ZETTABRAIN_EMBED_MODEL", "nomic-embed-text")
HASH_CACHE  = "./ingested_files.json"

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


def load_file(filepath: str):
    ext = Path(filepath).suffix.lower()
    if ext == ".pdf":
        return PyPDFLoader(filepath).load()
    elif ext in {".txt", ".md"}:
        return TextLoader(filepath, encoding="utf-8").load()
    elif ext in {".docx", ".doc"}:
        return Docx2txtLoader(filepath).load()
    return []


BATCH_SIZE = 50  # chunks per embedding call


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

    splitter = RecursiveCharacterTextSplitter(
        chunk_size=1500,
        chunk_overlap=200,
        separators=["\n\n\n", "\n\n", "\n", ". ", " ", ""]
    )
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

    embeddings  = OllamaEmbeddings(model=EMBED_MODEL)
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


if __name__ == "__main__":
    main()
