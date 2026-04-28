"""
ZettaBrain RAG — FastAPI Web Server
Serves the GUI and exposes REST + WebSocket endpoints.

Endpoints:
  GET  /                    → serve web UI
  GET  /api/status          → vector store + system status
  GET  /api/models          → available Ollama models
  POST /api/ingest          → trigger document ingestion
  POST /api/chat            → single query (returns full response)
  WS   /ws/chat             → streaming chat via WebSocket
  GET  /api/sources         → list ingested source files
  DELETE /api/vectorstore   → clear vector store
"""

import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

import requests
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# -------------------------------------------------------
# Paths
# -------------------------------------------------------
PKG_DIR    = Path(__file__).parent
STATIC_DIR = PKG_DIR / "static"
DEPLOY_DIR = Path("/opt/zettabrain/src")
CHROMA_PATH = DEPLOY_DIR / "zettabrain_vectorstore"
INGEST_LOG  = DEPLOY_DIR / "ingested_files.json"
NFS_CONFIG  = DEPLOY_DIR / "nfs_config.env"

OLLAMA_URL  = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
LLM_MODEL   = os.environ.get("ZETTABRAIN_LLM_MODEL", "llama3.1:8b")
EMBED_MODEL = os.environ.get("ZETTABRAIN_EMBED_MODEL", "nomic-embed-text")
DOCS_FOLDER = os.environ.get("ZETTABRAIN_DOCS", "/mnt/Rag-data")

# -------------------------------------------------------
# App
# -------------------------------------------------------
app = FastAPI(title="ZettaBrain RAG", version="0.1.6")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static files
if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


# -------------------------------------------------------
# Models
# -------------------------------------------------------
class ChatRequest(BaseModel):
    question: str
    model: Optional[str] = None


class IngestRequest(BaseModel):
    folder: Optional[str] = None
    rebuild: bool = False


# -------------------------------------------------------
# Helpers
# -------------------------------------------------------
def _get_python() -> str:
    """Find the Python that has langchain installed."""
    candidates = [
        *list(Path("/root/.local/share/pipx/venvs/zettabrain-rag").rglob("python3")),
        *list(Path("/opt/zettabrain/venv/bin").glob("python3")),
        Path(sys.executable),
    ]
    for c in candidates:
        if c.exists():
            result = subprocess.run(
                [str(c), "-c", "import langchain_community"],
                capture_output=True
            )
            if result.returncode == 0:
                return str(c)
    return sys.executable


def _ollama_running() -> bool:
    try:
        r = requests.get(f"{OLLAMA_URL}", timeout=3)
        return r.status_code == 200
    except Exception:
        return False


def _get_chunk_count() -> int:
    try:
        import chromadb
        client = chromadb.PersistentClient(path=str(CHROMA_PATH))
        col = client.get_collection("zettabrain_docs")
        return col.count()
    except Exception:
        return 0


def _get_sources() -> list:
    if not INGEST_LOG.exists():
        return []
    try:
        data = json.loads(INGEST_LOG.read_text())
        return sorted([Path(p).name for p in data.keys()])
    except Exception:
        return []


def _get_nfs_config() -> dict:
    config = {}
    if NFS_CONFIG.exists():
        for line in NFS_CONFIG.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                config[k.strip()] = v.strip().strip('"')
    return config


def _get_ollama_models() -> list:
    try:
        r = requests.get(f"{OLLAMA_URL}/api/tags", timeout=5)
        if r.status_code == 200:
            return [m["name"] for m in r.json().get("models", [])]
    except Exception:
        pass
    return []


# -------------------------------------------------------
# Routes
# -------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
async def root():
    """Serve the main web UI."""
    index = STATIC_DIR / "index.html"
    if index.exists():
        return HTMLResponse(index.read_text())
    return HTMLResponse("<h1>ZettaBrain</h1><p>Static files not found.</p>")


@app.get("/api/status")
async def status():
    nfs = _get_nfs_config()
    chunks = _get_chunk_count()
    sources = _get_sources()
    models = _get_ollama_models()
    ollama_ok = _ollama_running()

    # Count docs on NFS mount
    doc_count = 0
    docs_path = Path(nfs.get("RAG_DATA_PATH", DOCS_FOLDER))
    if docs_path.exists():
        for ext in ["*.pdf", "*.txt", "*.docx", "*.md"]:
            doc_count += len(list(docs_path.rglob(ext)))

    return {
        "ollama": {
            "running": ollama_ok,
            "url": OLLAMA_URL,
            "models": models,
            "active_llm": LLM_MODEL,
            "active_embed": EMBED_MODEL,
        },
        "vectorstore": {
            "exists": CHROMA_PATH.exists(),
            "chunks": chunks,
            "path": str(CHROMA_PATH),
        },
        "nfs": {
            "configured": bool(nfs),
            "server": nfs.get("NFS_SERVER_IP", ""),
            "export": nfs.get("NFS_EXPORT_PATH", ""),
            "mount": nfs.get("NFS_MOUNT_POINT", "/mnt/Rag-data"),
            "doc_count": doc_count,
        },
        "sources": sources,
    }


@app.get("/api/models")
async def get_models():
    return {"models": _get_ollama_models()}


@app.get("/api/sources")
async def get_sources():
    return {"sources": _get_sources()}


@app.post("/api/ingest")
async def ingest(req: IngestRequest):
    """Trigger document ingestion in background."""
    python = _get_python()
    script = DEPLOY_DIR / "05_ingest_documents.py"

    if not script.exists():
        raise HTTPException(status_code=404, detail=f"Ingest script not found: {script}")

    cmd = [python, str(script)]
    if req.folder:
        cmd += ["--folder", req.folder]
    if req.rebuild:
        cmd += ["--rebuild"]

    try:
        result = subprocess.run(
            cmd,
            cwd=str(DEPLOY_DIR),
            capture_output=True,
            text=True,
            timeout=600
        )
        return {
            "success": result.returncode == 0,
            "output": result.stdout,
            "error": result.stderr if result.returncode != 0 else None,
            "chunks": _get_chunk_count(),
        }
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=408, detail="Ingestion timed out (600s). Try smaller batches.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/chat")
async def chat(req: ChatRequest):
    """Single-shot chat query — returns complete response."""
    if not _ollama_running():
        raise HTTPException(status_code=503, detail="Ollama is not running. Start it with: ollama serve")

    chunks = _get_chunk_count()
    if chunks == 0:
        raise HTTPException(status_code=422, detail="Vector store is empty. Run ingestion first.")

    model = req.model or LLM_MODEL

    try:
        from langchain_ollama import OllamaEmbeddings, OllamaLLM
        from langchain_chroma import Chroma
        from langchain_core.prompts import PromptTemplate
        from langchain_core.runnables import RunnablePassthrough
        from langchain_core.output_parsers import StrOutputParser

        embeddings = OllamaEmbeddings(model=EMBED_MODEL, base_url=OLLAMA_URL)
        vectorstore = Chroma(
            persist_directory=str(CHROMA_PATH),
            embedding_function=embeddings,
            collection_name="zettabrain_docs"
        )
        retriever = vectorstore.as_retriever(
            search_type="mmr",
            search_kwargs={"k": 6, "fetch_k": 20, "lambda_mult": 0.7}
        )

        prompt = PromptTemplate.from_template(
            """You are ZettaBrain, an intelligent assistant that answers questions from documents.

INSTRUCTIONS:
- Answer using the context below. Be specific and detailed.
- If context is insufficient, say so clearly.
- Always answer in plain English.

CONTEXT:
{context}

QUESTION: {question}

ANSWER:"""
        )

        def format_docs(docs):
            return "\n\n---\n\n".join(
                f"[Source: {Path(d.metadata.get('source','?')).name}]\n{d.page_content}"
                for d in docs
            )

        llm = OllamaLLM(model=model, base_url=OLLAMA_URL, temperature=0.0, num_predict=1024)

        sources = retriever.invoke(req.question)
        chain = (
            {"context": retriever | format_docs, "question": RunnablePassthrough()}
            | prompt | llm | StrOutputParser()
        )
        answer = chain.invoke(req.question)

        return {
            "answer": answer,
            "sources": [
                {
                    "filename": Path(s.metadata.get("source", "?")).name,
                    "page": s.metadata.get("page", ""),
                    "preview": s.page_content[:200],
                }
                for s in sources
            ],
            "model": model,
            "chunks_searched": len(sources),
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.websocket("/ws/chat")
async def websocket_chat(websocket: WebSocket):
    """Streaming chat via WebSocket — tokens sent as they generate."""
    await websocket.accept()

    try:
        while True:
            data = await websocket.receive_text()
            payload = json.loads(data)
            question = payload.get("question", "").strip()
            model = payload.get("model", LLM_MODEL)

            if not question:
                await websocket.send_json({"type": "error", "message": "Empty question"})
                continue

            if not _ollama_running():
                await websocket.send_json({"type": "error", "message": "Ollama is not running"})
                continue

            if _get_chunk_count() == 0:
                await websocket.send_json({"type": "error", "message": "Vector store is empty — run ingestion first"})
                continue

            try:
                from langchain_ollama import OllamaEmbeddings, OllamaLLM
                from langchain_chroma import Chroma
                from langchain_core.prompts import PromptTemplate
                from langchain_core.runnables import RunnablePassthrough
                from langchain_core.output_parsers import StrOutputParser

                embeddings = OllamaEmbeddings(model=EMBED_MODEL, base_url=OLLAMA_URL)
                vectorstore = Chroma(
                    persist_directory=str(CHROMA_PATH),
                    embedding_function=embeddings,
                    collection_name="zettabrain_docs"
                )
                retriever = vectorstore.as_retriever(
                    search_type="mmr",
                    search_kwargs={"k": 6, "fetch_k": 20, "lambda_mult": 0.7}
                )

                # Retrieve sources first
                sources = retriever.invoke(question)
                source_list = [
                    {
                        "filename": Path(s.metadata.get("source", "?")).name,
                        "page": s.metadata.get("page", ""),
                        "preview": s.page_content[:200],
                    }
                    for s in sources
                ]

                # Send sources immediately
                await websocket.send_json({"type": "sources", "sources": source_list})

                # Stream the answer token by token via Ollama API directly
                context = "\n\n---\n\n".join(
                    f"[Source: {Path(s.metadata.get('source','?')).name}]\n{s.page_content}"
                    for s in sources
                )
                prompt_text = f"""You are ZettaBrain, an intelligent assistant that answers questions from documents.

INSTRUCTIONS:
- Answer using the context below. Be specific and detailed.
- If context is insufficient, say so clearly.

CONTEXT:
{context}

QUESTION: {question}

ANSWER:"""

                # Stream via Ollama REST API
                response = requests.post(
                    f"{OLLAMA_URL}/api/generate",
                    json={"model": model, "prompt": prompt_text, "stream": True},
                    stream=True,
                    timeout=120
                )

                full_answer = ""
                for line in response.iter_lines():
                    if line:
                        chunk = json.loads(line)
                        token = chunk.get("response", "")
                        full_answer += token
                        await websocket.send_json({"type": "token", "token": token})
                        if chunk.get("done"):
                            break

                await websocket.send_json({
                    "type": "done",
                    "answer": full_answer,
                    "model": model,
                })

            except Exception as e:
                await websocket.send_json({"type": "error", "message": str(e)})

    except WebSocketDisconnect:
        pass


@app.delete("/api/vectorstore")
async def clear_vectorstore():
    """Clear the vector store and ingestion log."""
    try:
        import chromadb
        client = chromadb.PersistentClient(path=str(CHROMA_PATH))
        client.delete_collection("zettabrain_docs")
        if INGEST_LOG.exists():
            INGEST_LOG.write_text("{}")
        return {"success": True, "message": "Vector store cleared."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
