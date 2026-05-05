#!/bin/bash
# ============================================================
# ZettaBrain RAG — One-line Installer
# Usage: curl -fsSL https://zettabrain.app/install.sh | sudo bash
# ============================================================

set -e

LOG_FILE="/var/log/zettabrain-install.log"
EMBED_MODEL="nomic-embed-text"

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true; }
info()    { echo -e "${CYAN}  →${NC} $*";  log "INFO  $*"; }
success() { echo -e "${GREEN}  ✓${NC} $*"; log "OK    $*"; }
warn()    { echo -e "${YELLOW}  !${NC} $*"; log "WARN  $*"; }
die()     { echo -e "${RED}  ✗ ERROR:${NC} $*"; log "ERROR $*"; echo ""; exit 1; }
step()    { echo ""; echo -e "${BOLD}${BLUE}[$1]${NC} $2"; }

# ── Banner ───────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${BLUE}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║               ZettaBrain RAG                        ║"
echo "  ║   Local private AI — your data stays on device      ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ── Root check ───────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  die "This installer must be run as root.\n  Run: curl -fsSL https://zettabrain.app/install.sh | sudo bash"
fi

mkdir -p /var/log

# ── 1/4 OS detection ─────────────────────────────────────────
step "1/4" "Detecting operating system"

OS=""
PKG_MANAGER=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS="${ID}"
fi

case "$OS" in
  ubuntu|debian|linuxmint|pop) PKG_MANAGER="apt" ;;
  amzn|rhel|centos|fedora|rocky|almalinux)
    PKG_MANAGER="yum"
    command -v dnf &>/dev/null && PKG_MANAGER="dnf" ;;
  *)
    command -v apt-get &>/dev/null && PKG_MANAGER="apt"
    command -v yum     &>/dev/null && PKG_MANAGER="yum"
    command -v dnf     &>/dev/null && PKG_MANAGER="dnf" ;;
esac

[ -z "$PKG_MANAGER" ] && die "Cannot detect package manager. Supported: apt, yum, dnf."
success "Detected: ${OS} (${PKG_MANAGER})"

# ── 2/4 System dependencies ──────────────────────────────────
step "2/4" "Installing system dependencies"

_pkg() {
  case "$PKG_MANAGER" in
    apt)     apt-get install -y -qq "$@" >> "$LOG_FILE" 2>&1 ;;
    yum|dnf) "$PKG_MANAGER" install -y -q "$@" >> "$LOG_FILE" 2>&1 ;;
  esac
}

# Find Python 3.9+
PYTHON_BIN=""
for py in python3.12 python3.11 python3.10 python3.9 python3; do
  if command -v "$py" &>/dev/null; then
    PY_NUM=$("$py" -c "import sys; print(sys.version_info.major*10+sys.version_info.minor)" 2>/dev/null || echo 0)
    if [ "$PY_NUM" -ge 39 ] 2>/dev/null; then
      PYTHON_BIN="$py"
      break
    fi
  fi
done

if [ -z "$PYTHON_BIN" ]; then
  info "Installing Python 3.11..."
  case "$PKG_MANAGER" in
    apt) apt-get update -qq >> "$LOG_FILE" 2>&1; _pkg python3.11 python3.11-venv python3-pip ;;
    yum|dnf) _pkg python3.11 ;;
  esac
  PYTHON_BIN="python3.11"
fi

success "Python: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

case "$PKG_MANAGER" in
  apt) apt-get update -qq >> "$LOG_FILE" 2>&1; _pkg python3-pip python3-venv curl git ;;
  yum|dnf) _pkg python3-pip curl git ;;
esac

success "System dependencies installed."

# ── 3/4 Install ZettaBrain RAG via pipx ──────────────────────
step "3/4" "Installing ZettaBrain RAG"

# Install pipx if missing
if ! command -v pipx &>/dev/null; then
  info "Installing pipx..."
  "$PYTHON_BIN" -m pip install --quiet --upgrade pipx >> "$LOG_FILE" 2>&1
  "$PYTHON_BIN" -m pipx ensurepath >> "$LOG_FILE" 2>&1
  export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
  hash -r 2>/dev/null || true
fi

# Install or upgrade
if pipx list 2>/dev/null | grep -q "zettabrain-rag"; then
  info "Upgrading zettabrain-rag to latest..."
  pipx upgrade zettabrain-rag >> "$LOG_FILE" 2>&1
else
  info "Installing zettabrain-rag from PyPI..."
  pipx install zettabrain-rag >> "$LOG_FILE" 2>&1
fi

INSTALLED_VERSION=$(zettabrain --version 2>/dev/null || pipx list 2>/dev/null | grep zettabrain | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "latest")
success "Installed: ${INSTALLED_VERSION}"

# ── 4/4 Install Ollama ───────────────────────────────────────
step "4/4" "Installing Ollama + embedding model"

if command -v ollama &>/dev/null; then
  info "Ollama already installed: $(ollama --version 2>/dev/null | head -1)"
else
  info "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh >> "$LOG_FILE" 2>&1
  success "Ollama installed."
fi

systemctl enable ollama >> "$LOG_FILE" 2>&1 || true
if ! systemctl is-active --quiet ollama 2>/dev/null; then
  info "Starting Ollama service..."
  systemctl start ollama >> "$LOG_FILE" 2>&1 || true
  sleep 3
fi

info "Pulling embedding model: ${EMBED_MODEL} (~275MB)..."
ollama pull "$EMBED_MODEL" 2>&1 | tail -1
success "Embedding model ready."

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         ZettaBrain RAG installed successfully!       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Version  : ${GREEN}${INSTALLED_VERSION}${NC}"
echo -e "  Log file : ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${BOLD}  Next steps:${NC}"
echo ""
echo -e "  1. Run setup — storage, TLS, and model selection:"
echo -e "     ${CYAN}sudo zettabrain-setup${NC}"
echo ""
echo -e "  2. Launch the secure web GUI:"
echo -e "     ${CYAN}zettabrain-server${NC}"
echo -e "     Open: ${CYAN}https://local.zettabrain.app:7860${NC}"
echo ""
echo -e "  3. Or start the CLI chat:"
echo -e "     ${CYAN}zettabrain-chat${NC}"
echo ""

log "Installation completed. Version: ${INSTALLED_VERSION}"
