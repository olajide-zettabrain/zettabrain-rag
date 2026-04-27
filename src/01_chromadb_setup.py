"""
ZettaBrain — ChromaDB Setup Diagnostic
Run this to verify ChromaDB is working correctly after install.

Usage:
    python 01_chromadb_setup.py
"""

import chromadb
from chromadb.config import Settings
import os

CHROMA_PATH = os.environ.get("ZETTABRAIN_CHROMA", "./zettabrain_vectorstore")

client = chromadb.PersistentClient(
    path=CHROMA_PATH,
    settings=Settings(anonymized_telemetry=False)
)

collection = client.get_or_create_collection(
    name="zettabrain_docs",
    metadata={"hnsw:space": "cosine"}
)

print(f"ChromaDB path      : {os.path.abspath(CHROMA_PATH)}")
print(f"Collection         : {collection.name}")
print(f"Chunks in store    : {collection.count()}")
print("\nChromaDB is working correctly.")
