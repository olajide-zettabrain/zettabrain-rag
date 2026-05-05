# ZettaBrain RAG

**Local private RAG pipeline — your documents, your hardware, zero cloud.**

Chat with your documents using a fully local AI. No API keys. No data leaving your machine. Runs on your own server or laptop with a secure HTTPS web GUI.

---

## Quick Install

```bash
curl -fsSL https://zettabrain.app/install.sh | sudo bash
```

Alternative mirror:

```bash
curl -fsSL https://install.zettabrain.io/install.sh | sudo bash
```

What the installer does:
- Detects your OS (Ubuntu, Debian, Amazon Linux, RHEL, Fedora)
- Installs Python 3.9+ and system dependencies
- Installs `zettabrain-rag` via **pipx** (isolated, no virtualenv management needed)
- Installs and starts Ollama
- Pulls the `nomic-embed-text` embedding model (~275 MB)

---

## Install via pipx (developers)

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

## First-time setup

### 1. Run setup wizard

```bash
sudo zettabrain-setup
```

Configures storage (Local / NFS / SMB), selects an LLM model based on your hardware, and enables HTTPS.

### 2. Launch the web GUI

```bash
zettabrain-server
```

Open **https://local.zettabrain.app:7860** in your browser — trusted HTTPS, fully private.

### 3. Or use the CLI chat

```bash
zettabrain-chat
```

---

## Commands

| Command | Description |
|---|---|
| `sudo zettabrain-setup` | Storage wizard + model selection + TLS cert |
| `zettabrain-server` | Launch secure HTTPS web GUI (port 7860) |
| `zettabrain-chat` | Interactive RAG chat in the terminal |
| `zettabrain-chat --rebuild` | Rebuild vector store then start chat |
| `zettabrain-chat --debug` | Show retrieved chunks on every query |
| `zettabrain-ingest` | Ingest documents into the vector store |
| `zettabrain-ingest --folder /path` | Ingest a specific folder |
| `zettabrain-ingest --file /path/doc.pdf` | Ingest a single file |
| `zettabrain-ingest --stats` | Show what is in the vector store |
| `zettabrain-ingest --clear` | Wipe the vector store |
| `zettabrain-status` | Show install paths, cert info, and store statistics |
| `sudo zettabrain-storage add` | Add a new storage source after initial setup |
| `zettabrain-storage list` | List configured storage sources |

### CLI chat commands

While inside `zettabrain-chat`:

| Type | Action |
|---|---|
| Any question | Query your documents |
| `sources` | Show which document chunks were used |
| `timing` | Show retrieve / generate time for all queries this session |
| `debug on` | Show retrieved chunks on every query |
| `debug off` | Hide debug output |
| `quit` | Exit |

---

## System requirements

| | Minimum | Recommended |
|---|---|---|
| **RAM** | 8 GB | 16 GB |
| **CPU** | 4 cores / 2.5 GHz | 8 cores / 3.0 GHz |
| **Disk** | 20 GB free | 50 GB free |
| **OS** | Ubuntu 22.04 / Debian 12 | Ubuntu 22.04 LTS |
| **Python** | 3.9 | 3.11+ |

> **Why 8 GB minimum:** `llama3.1:8b` (Q4) needs ~5 GB in RAM, plus ~2 GB for OS + Python + ChromaDB. Below 8 GB you will hit swap and responses can take 5+ minutes.

---

## GPU & model selection

Ollama **auto-detects your GPU** on install — NVIDIA (CUDA), AMD (ROCm), and Apple Silicon (Metal). No configuration needed beyond having the correct drivers installed.

`sudo zettabrain-setup` detects your hardware and presents a model menu:

```
Hardware detected: NVIDIA GeForce RTX 3080 (10GB VRAM)
Recommended model: llama3.1:8b  (10GB VRAM detected: balanced quality/speed)

  Available models:
    1) llama3.2:3b    — fastest (~2GB)        good for quick Q&A
    2) llama3.1:8b    — balanced (~5GB)       recommended for most   ← default
    3) mistral:7b     — fast (~4GB)           strong reasoning
    4) llama3.1:13b   — better (~8GB)         needs 12GB+ VRAM/RAM
    5) qwen2.5:14b    — excellent (~9GB)      needs 16GB+ VRAM/RAM
    6) qwen2.5:32b    — best quality (~20GB)  needs 24GB+ VRAM/RAM
    7) Custom
```

You can also switch model at any time by editing `/opt/zettabrain/src/zettabrain.env`:

```bash
ZETTABRAIN_LLM_MODEL=qwen2.5:14b
```

Then restart the server: `zettabrain-server`

### Performance reference

Approximate response time for a 300-token answer ("What is cloud computing?"):

| Hardware | Model | Tokens/sec | Response time |
|---|---|---|---|
| 4-core CPU, 8 GB RAM | llama3.2:3b | 8–15 t/s | 20–40 s |
| 8-core CPU, 16 GB RAM | llama3.1:8b | 5–12 t/s | 25–60 s |
| NVIDIA RTX 3060 (8 GB) | llama3.1:8b | 60–90 t/s | 3–5 s |
| NVIDIA RTX 3080 (10 GB) | llama3.1:8b | 80–120 t/s | 2–4 s |
| Apple M2 (16 GB) | llama3.1:8b | 30–50 t/s | 6–10 s |

The web UI and CLI both show per-query timing: retrieve time, generate time, and delta vs previous query.

---

## Retrieval pipeline

ZettaBrain uses a hybrid retrieval approach for accuracy:

1. **Adaptive chunking** — chunk size tuned per document type (PDF / DOCX / TXT) and text density
2. **MMR semantic search** — Maximum Marginal Relevance via ChromaDB (diversity + relevance)
3. **BM25 keyword search** — exact term matching on the same corpus
4. **Merge & deduplicate** — semantic results ranked first, duplicates removed by content hash
5. **Cross-encoder re-ranking** — FlashRank (`ms-marco-MiniLM-L-12-v2`) picks the best chunks before sending to the LLM

---

## Supported document formats

`.pdf`  `.txt`  `.md`  `.docx`

---

## Configuration

All settings can be overridden via environment variables or `/opt/zettabrain/src/zettabrain.env`:

| Variable | Default | Description |
|---|---|---|
| `ZETTABRAIN_DOCS` | `/opt/zettabrain/data` | Documents folder |
| `ZETTABRAIN_CHROMA` | `/opt/zettabrain/src/zettabrain_vectorstore` | ChromaDB path |
| `ZETTABRAIN_LLM_MODEL` | `llama3.1:8b` | Ollama LLM model |
| `ZETTABRAIN_EMBED_MODEL` | `nomic-embed-text` | Ollama embedding model |
| `ZETTABRAIN_CHUNK_SIZE` | `1000` (PDF) / `800` (TXT) | Chunk size (adaptive) |
| `ZETTABRAIN_CHUNK_OVERLAP` | `150` (PDF) / `100` (TXT) | Chunk overlap (adaptive) |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API endpoint |

---

## Diagnostics

```bash
# Full status — version, certs, vector store stats
zettabrain-status

# Verify ChromaDB is working
python3 /opt/zettabrain/src/01_chromadb_setup.py

# Verify embedding model is working
python3 /opt/zettabrain/src/02_embeddings_test.py

# Check Ollama is running
curl http://localhost:11434

# List downloaded models
ollama list

# View server logs
journalctl -u zettabrain -f
```

---

## Uninstall

### pipx install
```bash
pipx uninstall zettabrain-rag
sudo rm -rf /opt/zettabrain
```

### One-line installer
```bash
pipx uninstall zettabrain-rag
sudo rm -rf /opt/zettabrain /var/log/zettabrain-install.log
sudo systemctl disable --now zettabrain 2>/dev/null || true
```

---

## Contributors

| | |
|---|---|
| **[@olajide-zettabrain](https://github.com/olajide-zettabrain)** | Creator & maintainer |

---

## License

MIT — © ZettaBrain
