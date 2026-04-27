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
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser

# -------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------
DOCS_FOLDER   = "/mnt/Rag-data"
CHROMA_PATH   = "./zettabrain_vectorstore"
EMBED_MODEL   = "nomic-embed-text"
LLM_MODEL     = "llama3.1:8b"
CHUNK_SIZE    = 1500    # larger = more context per chunk
CHUNK_OVERLAP = 200     # more overlap = fewer missed boundaries
DEBUG         = False   # set True to see retrieved chunks on every query


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
def get_vectorstore(chunks=None, force_rebuild=False):
    embeddings = OllamaEmbeddings(model=EMBED_MODEL)

    if os.path.exists(CHROMA_PATH) and not force_rebuild:
        print(f"Loading existing vector store from: {CHROMA_PATH}")
        vs = Chroma(
            persist_directory=CHROMA_PATH,
            embedding_function=embeddings,
            collection_name="zettabrain_docs"
        )
        count = vs._collection.count()
        if count == 0:
            print("WARNING: Vector store is empty — forcing rebuild")
            return get_vectorstore(chunks, force_rebuild=True)
        print(f"Loaded {count} chunks.")
        return vs

    if not chunks:
        raise ValueError("No chunks provided and no existing vector store found.")

    print(f"Embedding {len(chunks)} chunks with {EMBED_MODEL}...")
    print("(This will take a few minutes)")

    vs = Chroma.from_documents(
        documents=chunks,
        embedding=embeddings,
        persist_directory=CHROMA_PATH,
        collection_name="zettabrain_docs"
    )
    print(f"Vector store saved to: {CHROMA_PATH}")
    return vs


# -------------------------------------------------------
# 4. BUILD RAG CHAIN
# -------------------------------------------------------
def build_rag_chain(vectorstore):
    llm = OllamaLLM(
        model=LLM_MODEL,
        temperature=0.0,
        num_predict=1024
    )

    # MMR = Maximum Marginal Relevance
    # Returns diverse chunks instead of 6 near-identical ones
    retriever = vectorstore.as_retriever(
        search_type="mmr",
        search_kwargs={
            "k": 6,
            "fetch_k": 20,
            "lambda_mult": 0.7
        }
    )

    prompt_template = PromptTemplate.from_template("""You are ZettaBrain, an intelligent assistant that answers questions based on a knowledge base of documents.

INSTRUCTIONS:
- Read the context carefully and answer the question using information found in it.
- Be specific and detailed in your answer.
- If the context contains partial information, use what is available and say so.
- Only say the topic is not covered if the context is completely unrelated to the question.
- Always answer in clear, plain English.

CONTEXT FROM YOUR DOCUMENTS:
{context}

QUESTION: {question}

ANSWER:""")

    def format_docs(docs):
        formatted = []
        for doc in docs:
            source = Path(doc.metadata.get("source", "unknown")).name
            formatted.append(f"[Source: {source}]\n{doc.page_content}")
        return "\n\n---\n\n".join(formatted)

    chain = (
        {
            "context":  retriever | format_docs,
            "question": RunnablePassthrough()
        }
        | prompt_template
        | llm
        | StrOutputParser()
    )

    return chain, retriever


# -------------------------------------------------------
# 5. INTERACTIVE CHAT
# -------------------------------------------------------
def chat(chain, retriever):
    print("\n" + "="*60)
    print("ZettaBrain Local RAG v2")
    print("Commands: 'sources' | 'debug on/off' | 'quit'")
    print("="*60 + "\n")

    last_sources = []
    debug = DEBUG

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

        if query.lower() == "debug on":
            debug = True
            print("Debug mode ON — retrieved chunks shown on every query\n")
            continue

        if query.lower() == "debug off":
            debug = False
            print("Debug mode OFF\n")
            continue

        print("Thinking...\n")

        last_sources = retriever.invoke(query)

        if debug:
            print(f"[DEBUG] {len(last_sources)} chunks retrieved:")
            for i, doc in enumerate(last_sources, 1):
                src = Path(doc.metadata.get("source", "?")).name
                print(f"  [{i}] {src}: {doc.page_content[:150]}")
            print()

        answer = chain.invoke(query)
        print(f"Assistant: {answer}\n")
        print(f"[{len(last_sources)} chunks used — type 'sources' for details]\n")


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

    print(f"\n[1/4] Loading documents from {DOCS_FOLDER}...")
    documents = load_documents(DOCS_FOLDER)

    if documents:
        print(f"\n[2/4] Splitting {len(documents)} documents...")
        chunks = split_documents(documents)
        print("\n[3/4] Setting up vector store...")
        vectorstore = get_vectorstore(chunks, force_rebuild=args.rebuild)
    else:
        print("\n[2/4] No documents found — loading existing vector store...")
        vectorstore = get_vectorstore()

    print("\n[4/4] Building RAG chain...")
    chain, retriever = build_rag_chain(vectorstore)

    chat(chain, retriever)
