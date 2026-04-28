"""
ZettaBrain RAG — Streamlit GUI
Run with: zettabrain-ui
Or directly: streamlit run 04_gui.py
"""

import os
import json
import time
from pathlib import Path

import streamlit as st

# -------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------
DOCS_FOLDER  = os.environ.get("ZETTABRAIN_DOCS",        "/mnt/Rag-data")
CHROMA_PATH  = os.environ.get("ZETTABRAIN_CHROMA",       "./zettabrain_vectorstore")
EMBED_MODEL  = os.environ.get("ZETTABRAIN_EMBED_MODEL",  "nomic-embed-text")
LLM_MODEL    = os.environ.get("ZETTABRAIN_LLM_MODEL",    "llama3.1:8b")
OLLAMA_URL   = os.environ.get("OLLAMA_HOST",              "http://localhost:11434")
INGEST_LOG   = "./ingested_files.json"

# -------------------------------------------------------
# PAGE CONFIG
# -------------------------------------------------------
st.set_page_config(
    page_title="ZettaBrain RAG",
    page_icon="🧠",
    layout="wide",
    initial_sidebar_state="expanded"
)

# -------------------------------------------------------
# CUSTOM CSS
# -------------------------------------------------------
st.markdown("""
<style>
  /* Main header */
  .zb-header {
    background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
    padding: 1.5rem 2rem;
    border-radius: 12px;
    margin-bottom: 1.5rem;
    color: white;
  }
  .zb-header h1 { color: white; margin: 0; font-size: 1.8rem; }
  .zb-header p  { color: #94a3b8; margin: 4px 0 0 0; font-size: 0.9rem; }

  /* Stat cards */
  .stat-card {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 10px;
    padding: 1rem;
    text-align: center;
    color: white;
  }
  .stat-card .value { font-size: 1.8rem; font-weight: 700; color: #38bdf8; }
  .stat-card .label { font-size: 0.75rem; color: #94a3b8; margin-top: 4px; }

  /* Source badge */
  .source-badge {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 8px;
    padding: 0.5rem 0.75rem;
    margin: 4px 0;
    font-size: 0.8rem;
    color: #94a3b8;
  }
  .source-badge strong { color: #38bdf8; }

  /* Status indicator */
  .status-ok   { color: #22c55e; font-weight: 600; }
  .status-warn { color: #f59e0b; font-weight: 600; }
  .status-err  { color: #ef4444; font-weight: 600; }

  /* Hide streamlit branding */
  #MainMenu { visibility: hidden; }
  footer     { visibility: hidden; }
</style>
""", unsafe_allow_html=True)


# -------------------------------------------------------
# CACHED RESOURCES
# -------------------------------------------------------
@st.cache_resource(show_spinner="Loading vector store...")
def load_vectorstore():
    from langchain_ollama import OllamaEmbeddings
    from langchain_chroma import Chroma
    embeddings = OllamaEmbeddings(model=EMBED_MODEL, base_url=OLLAMA_URL)
    return Chroma(
        persist_directory=CHROMA_PATH,
        embedding_function=embeddings,
        collection_name="zettabrain_docs"
    )


@st.cache_resource(show_spinner="Building RAG chain...")
def load_chain():
    from langchain_ollama import OllamaLLM
    from langchain_core.prompts import PromptTemplate
    from langchain_core.runnables import RunnablePassthrough
    from langchain_core.output_parsers import StrOutputParser

    vectorstore = load_vectorstore()

    llm = OllamaLLM(
        model=LLM_MODEL,
        base_url=OLLAMA_URL,
        temperature=0.0,
        num_predict=1024
    )

    retriever = vectorstore.as_retriever(
        search_type="mmr",
        search_kwargs={"k": 6, "fetch_k": 20, "lambda_mult": 0.7}
    )

    prompt = PromptTemplate.from_template("""You are ZettaBrain, an intelligent assistant answering questions from a private document knowledge base.

INSTRUCTIONS:
- Answer using ONLY information found in the context below.
- Be specific and detailed.
- If context is partially relevant, use what is available and note any gaps.
- If context is completely unrelated, say so clearly.

CONTEXT:
{context}

QUESTION: {question}

ANSWER:""")

    def format_docs(docs):
        parts = []
        for doc in docs:
            source = Path(doc.metadata.get("source", "unknown")).name
            parts.append(f"[Source: {source}]\n{doc.page_content}")
        return "\n\n---\n\n".join(parts)

    chain = (
        {"context": retriever | format_docs, "question": RunnablePassthrough()}
        | prompt
        | llm
        | StrOutputParser()
    )

    return chain, retriever


# -------------------------------------------------------
# HELPER FUNCTIONS
# -------------------------------------------------------
def check_ollama() -> bool:
    import urllib.request
    try:
        urllib.request.urlopen(OLLAMA_URL, timeout=3)
        return True
    except Exception:
        return False


def get_store_stats() -> dict:
    if not Path(CHROMA_PATH).exists():
        return {"chunks": 0, "files": 0, "sources": []}
    try:
        vs = load_vectorstore()
        count = vs._collection.count()
        sources = []
        if Path(INGEST_LOG).exists():
            data = json.loads(Path(INGEST_LOG).read_text())
            sources = [Path(p).name for p in sorted(data.keys())]
        return {"chunks": count, "files": len(sources), "sources": sources}
    except Exception:
        return {"chunks": 0, "files": 0, "sources": []}


def get_doc_count() -> int:
    folder = Path(DOCS_FOLDER)
    if not folder.exists():
        return 0
    return len(list(folder.rglob("*.pdf")) +
               list(folder.rglob("*.txt")) +
               list(folder.rglob("*.docx")) +
               list(folder.rglob("*.md")))


def rebuild_vectorstore():
    """Trigger a full vector store rebuild."""
    from langchain_community.document_loaders import PyPDFLoader, TextLoader, Docx2txtLoader
    from langchain_text_splitters import RecursiveCharacterTextSplitter
    from langchain_ollama import OllamaEmbeddings
    from langchain_chroma import Chroma
    import shutil

    folder = Path(DOCS_FOLDER)
    if not folder.exists():
        st.error(f"Documents folder not found: {DOCS_FOLDER}")
        return False

    # Load all docs
    docs = []
    for f in folder.rglob("*.pdf"):
        try: docs.extend(PyPDFLoader(str(f)).load())
        except: pass
    for f in folder.rglob("*.txt"):
        try: docs.extend(TextLoader(str(f), encoding="utf-8").load())
        except: pass
    for f in folder.rglob("*.docx"):
        try: docs.extend(Docx2txtLoader(str(f)).load())
        except: pass
    for f in folder.rglob("*.md"):
        try: docs.extend(TextLoader(str(f), encoding="utf-8").load())
        except: pass

    if not docs:
        st.warning("No documents found in the NFS share.")
        return False

    splitter = RecursiveCharacterTextSplitter(chunk_size=1500, chunk_overlap=200)
    chunks = splitter.split_documents(docs)

    # Wipe and rebuild
    if Path(CHROMA_PATH).exists():
        shutil.rmtree(CHROMA_PATH)

    embeddings = OllamaEmbeddings(model=EMBED_MODEL, base_url=OLLAMA_URL)
    Chroma.from_documents(
        documents=chunks,
        embedding=embeddings,
        persist_directory=CHROMA_PATH,
        collection_name="zettabrain_docs"
    )

    # Clear cached resources so they reload
    st.cache_resource.clear()
    return True


# -------------------------------------------------------
# SIDEBAR
# -------------------------------------------------------
with st.sidebar:
    st.markdown("## 🧠 ZettaBrain")
    st.markdown("---")

    # System Status
    st.markdown("### System Status")
    ollama_ok = check_ollama()
    store_ok  = Path(CHROMA_PATH).exists()

    col1, col2 = st.columns(2)
    with col1:
        if ollama_ok:
            st.markdown('<p class="status-ok">● Ollama</p>', unsafe_allow_html=True)
        else:
            st.markdown('<p class="status-err">● Ollama</p>', unsafe_allow_html=True)
    with col2:
        if store_ok:
            st.markdown('<p class="status-ok">● Vector DB</p>', unsafe_allow_html=True)
        else:
            st.markdown('<p class="status-warn">● Vector DB</p>', unsafe_allow_html=True)

    st.markdown("---")

    # Settings
    st.markdown("### Settings")
    selected_model = st.selectbox(
        "LLM Model",
        ["llama3.1:8b", "llama3.2:3b", "mistral:7b", "mistral-nemo:12b",
         "deepseek-r1:8b", "gemma2:9b", "phi3:medium"],
        index=0
    )
    if selected_model != LLM_MODEL:
        LLM_MODEL = selected_model
        st.cache_resource.clear()

    show_sources = st.toggle("Show Sources", value=True)
    show_debug   = st.toggle("Debug Mode",   value=False)

    st.markdown("---")

    # Vector Store Stats
    st.markdown("### Knowledge Base")
    stats = get_store_stats()
    doc_count = get_doc_count()

    c1, c2 = st.columns(2)
    with c1:
        st.metric("Chunks", stats["chunks"])
    with c2:
        st.metric("Files", stats["files"])

    st.caption(f"📁 NFS: `{DOCS_FOLDER}`")
    st.caption(f"🗄️ Store: `{CHROMA_PATH}`")

    st.markdown("---")

    # Knowledge Base Management
    st.markdown("### Manage")

    if st.button("🔄 Rebuild Index", use_container_width=True):
        with st.spinner("Rebuilding vector store from NFS documents..."):
            success = rebuild_vectorstore()
        if success:
            st.success("Index rebuilt successfully!")
            st.rerun()
        else:
            st.error("Rebuild failed. Check NFS mount.")

    if st.button("🗑️ Clear Chat", use_container_width=True):
        st.session_state.messages = []
        st.rerun()

    if stats["sources"]:
        with st.expander(f"📄 {len(stats['sources'])} indexed files"):
            for src in stats["sources"]:
                st.caption(f"• {src}")


# -------------------------------------------------------
# MAIN CONTENT
# -------------------------------------------------------

# Header
st.markdown("""
<div class="zb-header">
  <h1>🧠 ZettaBrain RAG</h1>
  <p>Local private AI — chat with your documents · Zero cloud · Your data stays on device</p>
</div>
""", unsafe_allow_html=True)

# Warning banners
if not check_ollama():
    st.error("⚠️ Ollama is not running. Start it with: `ollama serve`")
    st.stop()

if not Path(CHROMA_PATH).exists() or get_store_stats()["chunks"] == 0:
    st.warning("⚠️ Vector store is empty. Click **Rebuild Index** in the sidebar to index your documents.")

# -------------------------------------------------------
# CHAT INTERFACE
# -------------------------------------------------------

# Initialise session state
if "messages" not in st.session_state:
    st.session_state.messages = []
if "last_sources" not in st.session_state:
    st.session_state.last_sources = []

# Render chat history
for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])
        if msg["role"] == "assistant" and show_sources and msg.get("sources"):
            with st.expander(f"📄 {len(msg['sources'])} source chunks used"):
                for i, src in enumerate(msg["sources"], 1):
                    fname = Path(src["source"]).name
                    page  = f" · page {src['page']}" if src.get("page") else ""
                    st.markdown(f"""
                    <div class="source-badge">
                      <strong>[{i}] {fname}{page}</strong><br/>
                      {src['text'][:250]}...
                    </div>
                    """, unsafe_allow_html=True)

# Chat input
if prompt := st.chat_input("Ask a question about your documents..."):

    # Show user message
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    # Generate response
    with st.chat_message("assistant"):
        with st.spinner("Thinking..."):
            try:
                chain, retriever = load_chain()

                # Retrieve sources
                sources = retriever.invoke(prompt)

                if show_debug:
                    st.caption(f"🔍 Retrieved {len(sources)} chunks")
                    for i, doc in enumerate(sources, 1):
                        st.caption(f"  [{i}] {Path(doc.metadata.get('source','?')).name}: {doc.page_content[:100]}")

                # Stream the response
                response_placeholder = st.empty()
                full_response = ""

                answer = chain.invoke(prompt)
                # Simulate streaming for better UX
                for word in answer.split():
                    full_response += word + " "
                    response_placeholder.markdown(full_response + "▌")
                    time.sleep(0.015)
                response_placeholder.markdown(full_response)

                # Format sources for storage
                source_data = [
                    {
                        "source": doc.metadata.get("source", "unknown"),
                        "page":   doc.metadata.get("page", ""),
                        "text":   doc.page_content
                    }
                    for doc in sources
                ]

                # Show sources inline
                if show_sources and source_data:
                    with st.expander(f"📄 {len(source_data)} source chunks used"):
                        for i, src in enumerate(source_data, 1):
                            fname = Path(src["source"]).name
                            page  = f" · page {src['page']}" if src.get("page") else ""
                            st.markdown(f"""
                            <div class="source-badge">
                              <strong>[{i}] {fname}{page}</strong><br/>
                              {src['text'][:250]}...
                            </div>
                            """, unsafe_allow_html=True)

                # Save to history
                st.session_state.messages.append({
                    "role":    "assistant",
                    "content": full_response,
                    "sources": source_data
                })

            except Exception as e:
                err_msg = f"Error: {str(e)}"
                st.error(err_msg)
                st.session_state.messages.append({
                    "role": "assistant", "content": err_msg, "sources": []
                })
