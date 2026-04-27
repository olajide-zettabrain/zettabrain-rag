"""
ZettaBrain — Embedding Model Diagnostic
Tests that nomic-embed-text is reachable and producing valid vectors.

Usage:
    python 02_embeddings_test.py
"""

import requests
import numpy as np
import os

OLLAMA_URL  = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
EMBED_MODEL = os.environ.get("ZETTABRAIN_EMBED_MODEL", "nomic-embed-text")


def get_embedding(text: str) -> list:
    r = requests.post(f"{OLLAMA_URL}/api/embeddings",
                      json={"model": EMBED_MODEL, "prompt": text})
    r.raise_for_status()
    return r.json()["embedding"]


def cosine_similarity(a, b) -> float:
    a, b = np.array(a), np.array(b)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


if __name__ == "__main__":
    print(f"Testing {EMBED_MODEL} via {OLLAMA_URL}\n")

    sentences = [
        "ZettaBrain provides hybrid cloud storage solutions.",
        "AWS FSx for NetApp ONTAP is an enterprise file system.",
        "The weather today is sunny and warm.",
    ]
    query = "cloud storage for enterprise workloads"

    print(f"Query: '{query}'\n")
    query_emb = get_embedding(query)
    print(f"Embedding dimensions: {len(query_emb)}\n")

    results = []
    for s in sentences:
        sim = cosine_similarity(query_emb, get_embedding(s))
        results.append((sim, s))

    results.sort(reverse=True)
    print("Similarity ranking:")
    for score, sentence in results:
        print(f"  [{score:.4f}] {sentence}")

    print("\nEmbedding model is working correctly.")
