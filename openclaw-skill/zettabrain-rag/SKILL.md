---
name: zettabrain-rag
description: Chat with your private documents using a fully local RAG pipeline. No cloud, no API keys — runs on your own machine with Ollama + ChromaDB.
version: 1.0.0
emoji: "🧠"
homepage: https://zettabrain.io
metadata:
  openclaw:
    requires:
      bins: [zettabrain-chat, zettabrain-ingest, zettabrain-server, zettabrain-status]
      anyBins: [pipx, pip3]
    install:
      - kind: brew
        formula: pipx
        bins: [pipx]
    envVars:
      - name: ZETTABRAIN_DOCS
        required: false
        description: Path to your documents folder (e.g. ~/Documents/ZettaBrain). Overrides the value set during zettabrain-setup.
      - name: ZETTABRAIN_LLM_MODEL
        required: false
        description: Ollama model name to use (e.g. llama3.1:8b, qwen2.5:14b). Defaults to the model selected during setup.
      - name: OLLAMA_HOST
        required: false
        description: Ollama API URL (default http://localhost:11434). Change if Ollama runs on a remote host.
---

# ZettaBrain RAG Skill

Chat with your own documents using a fully local AI. No data leaves your machine — everything runs on-device with [Ollama](https://ollama.com) (LLM), ChromaDB (vector store), and LangChain.

Supports **PDF, DOCX, TXT, Markdown**. Works on Linux, macOS (including EC2 Mac Apple Silicon), and Windows.

## Install

**One-line installer (Linux / macOS):**
```bash
# Linux
curl -fsSL https://zettabrain.app/install.sh | sudo bash

# macOS
curl -fsSL https://zettabrain.app/install.sh | bash

# Windows
irm https://zettabrain.app/install.ps1 | iex
```

**Via pipx:**
```bash
pipx install zettabrain-rag
sudo zettabrain-setup      # Linux / macOS EC2
```

## Setup

Run the interactive setup wizard once after install:
```bash
sudo zettabrain-setup
```

This will:
1. Configure your document storage (local, NFS, SMB, or S3)
2. Install and start Ollama
3. Pull the recommended AI model for your hardware
4. Generate a TLS certificate
5. Register ZettaBrain as a system service (systemd on Linux, launchd on macOS)

## Commands

| Command | Description |
|---|---|
| `zettabrain-chat` | Interactive CLI chat with your documents |
| `zettabrain-server` | Start the web GUI server (HTTPS on port 7860) |
| `zettabrain-ingest` | Index documents into the vector store |
| `zettabrain-ingest --rebuild` | Re-index all documents from scratch |
| `zettabrain-status` | Show Ollama, vector store, and storage status |
| `zettabrain-storage add` | Add an additional storage source |
| `zettabrain-setup` | Re-run the setup wizard |

## Usage Examples

**Chat via CLI:**
```bash
zettabrain-chat
# > What does our Q3 report say about cloud costs?
```

**Start the web GUI (available at https://localhost:7860):**
```bash
zettabrain-server
```

**Ingest a new folder of documents:**
```bash
ZETTABRAIN_DOCS=/path/to/new-docs zettabrain-ingest
```

**Check system status:**
```bash
zettabrain-status
```

**Switch LLM model:**
```bash
ollama pull qwen2.5:14b
ZETTABRAIN_LLM_MODEL=qwen2.5:14b zettabrain-chat
```

## Configuration

Settings are stored in `/opt/zettabrain/src/zettabrain.env`. Key variables:

| Variable | Default | Description |
|---|---|---|
| `ZETTABRAIN_DOCS` | set during setup | Path to documents folder |
| `ZETTABRAIN_LLM_MODEL` | set during setup | Ollama model name |
| `ZETTABRAIN_EMBED_MODEL` | `nomic-embed-text` | Embedding model |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API endpoint |
| `ZETTABRAIN_CHUNK_SIZE` | `1000` | Document chunk size |
| `ZETTABRAIN_CHUNK_OVERLAP` | `200` | Chunk overlap |

## Supported Platforms

| Platform | Notes |
|---|---|
| Ubuntu 22.04 / 24.04 | Full GPU support (NVIDIA auto-installed) |
| Amazon Linux 2 / 2023 | Full support |
| RHEL / Rocky / AlmaLinux 8/9 | Full support |
| macOS 12+ Apple Silicon | Metal GPU via Ollama (`mac2.metal`, `mac2-m2.metal`) |
| macOS 12+ Intel | CPU inference (`mac1.metal`) |
| Windows 10/11 | Via PowerShell installer |

## Links

- **PyPI**: https://pypi.org/project/zettabrain-rag/
- **GitHub**: https://github.com/zettabrain/zettabrain-rag
- **Website**: https://zettabrain.io
- **Issues**: https://github.com/zettabrain/zettabrain-rag/issues
