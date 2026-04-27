# ZettaBrain RAG

**Local private RAG pipeline — your documents, your hardware, zero cloud.**

Chat with your documents using a fully local AI. No API keys. No data leaving your machine. Runs on your own server or laptop.

---

## Install

Choose the method that suits your environment:

---

### Option 1 — pipx (Recommended for developers)

[pipx](https://pipx.pypa.io) installs ZettaBrain into an isolated environment and exposes the CLI globally. No virtualenv management needed.

```bash
# Install pipx if you don't have it
apt install -y pipx          # Ubuntu / Debian
brew install pipx            # macOS

# Install ZettaBrain
pipx install zettabrain-rag

# Verify
zettabrain --version
```

---

### Option 2 — One-line installer (Recommended for servers)

The fastest path on a fresh Linux server. Handles Python, Ollama, NFS client, and all dependencies automatically.

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/zettabrain-rag/main/install.sh | sudo bash
```

What it does:
- Detects your OS (Ubuntu, Debian, Amazon Linux, RHEL)
- Installs Python, NFS client, and system dependencies
- Creates an isolated Python environment at `/opt/zettabrain/venv`
- Installs `zettabrain-rag` from PyPI
- Registers all CLI commands in `/usr/local/bin`
- Installs and starts Ollama
- Pulls the `nomic-embed-text` embedding model

---

## First-time setup (both options)

### 1. Pull the LLM model
```bash
ollama pull llama3.1:8b
```

### 2. Mount your NFS document store
```bash
sudo zettabrain-setup
```
Prompts for your NFS server IP and export path, mounts at `/mnt/Rag-data`, and builds the vector store automatically.

### 3. Start chatting
```bash
zettabrain-chat
```

---

## Commands

| Command | Description |
|---|---|
| `sudo zettabrain-setup` | NFS mount wizard + auto vector store build |
| `zettabrain-chat` | Start interactive RAG chat |
| `zettabrain-chat --rebuild` | Rebuild vector store then start chat |
| `zettabrain-chat --debug` | Show retrieved chunks on every query |
| `zettabrain-chat --model mistral:7b` | Use a different LLM |
| `zettabrain-ingest` | Ingest documents without starting chat |
| `zettabrain-ingest --folder /path` | Ingest a specific folder |
| `zettabrain-ingest --file /path/doc.pdf` | Ingest a single file |
| `zettabrain-ingest --rebuild` | Force full re-embed of all documents |
| `zettabrain-ingest --stats` | Show what is in the vector store |
| `zettabrain-ingest --clear` | Wipe the vector store |
| `zettabrain-status` | Show install paths and store statistics |

---

## Chat commands

While inside `zettabrain-chat`:

| Type | Action |
|---|---|
| Any question | Query your documents |
| `sources` | Show which document chunks were used |
| `debug on` | Show retrieved chunks on every query |
| `debug off` | Hide debug output |
| `quit` | Exit |

---

## Configuration

All settings can be overridden via environment variables:

```bash
export ZETTABRAIN_DOCS=/mnt/Rag-data
export ZETTABRAIN_CHROMA=./zettabrain_vectorstore
export ZETTABRAIN_LLM_MODEL=llama3.1:8b
export ZETTABRAIN_EMBED_MODEL=nomic-embed-text
export ZETTABRAIN_CHUNK_SIZE=1500
export ZETTABRAIN_CHUNK_OVERLAP=200
export OLLAMA_HOST=http://localhost:11434
```

---

## Supported document formats

`.pdf`  `.txt`  `.md`  `.docx`

---

## Hardware requirements

| RAM | Recommended model | Performance |
|---|---|---|
| 8GB | `llama3.2:3b` | Basic |
| 16GB | `llama3.1:8b` | Recommended |
| 32GB | `mistral-nemo:12b` | Better reasoning |
| Apple M3/M4 (16GB+) | `llama3.1:70b-q4` | Excellent |

---

## Diagnostics

```bash
# Verify ChromaDB is working
python3 /opt/zettabrain/src/01_chromadb_setup.py

# Verify embedding model is working
python3 /opt/zettabrain/src/02_embeddings_test.py

# Check Ollama is running
curl http://localhost:11434

# Check downloaded models
ollama list
```

---

## Uninstall

### pipx
```bash
pipx uninstall zettabrain-rag
```

### One-line installer
```bash
rm -rf /opt/zettabrain
rm -f /usr/local/bin/zettabrain*
```

---

## License

MIT — © ZettaBrain
