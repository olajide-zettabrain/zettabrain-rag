#!/bin/bash
# ============================================================
# ZettaBrain RAG — One-line Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/zettabrain-rag/main/install.sh | bash
# ============================================================

set -e

ZETTABRAIN_VERSION="0.1.1"
INSTALL_DIR="/opt/zettabrain"
BIN_DIR="/usr/local/bin"
VENV_DIR="${INSTALL_DIR}/venv"
SRC_DIR="${INSTALL_DIR}/src"
LOG_FILE="/var/log/zettabrain-install.log"

# CLI commands to symlink into /usr/local/bin
CLI_COMMANDS=(
  "zettabrain"
  "zettabrain-chat"
  "zettabrain-ingest"
  "zettabrain-setup"
  "zettabrain-status"
)

# Ollama models to pull
OLLAMA_LLM_MODEL="llama3.1:8b"
OLLAMA_EMBED_MODEL="nomic-embed-text"

# -------------------------------------------------------
# COLOURS
# -------------------------------------------------------
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
error()   { echo -e "${RED}  ✗ ERROR:${NC} $*"; log "ERROR $*"; }
die()     { error "$*"; echo ""; echo "  Check the log: ${LOG_FILE}"; exit 1; }
step()    { echo ""; echo -e "${BOLD}${BLUE}[$1]${NC} $2"; }

# -------------------------------------------------------
# BANNER
# -------------------------------------------------------
clear 2>/dev/null || true
echo ""
echo -e "${BLUE}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           ZettaBrain RAG  v${ZETTABRAIN_VERSION}                    ║"
echo "  ║   Local private AI — your data stays on device      ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Installing to: ${GREEN}${INSTALL_DIR}${NC}"
echo -e "  CLI tools at : ${GREEN}${BIN_DIR}${NC}"
echo ""

# -------------------------------------------------------
# ROOT CHECK
# -------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  die "This installer must be run as root.\nRun: curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/zettabrain-rag/main/install.sh | sudo bash"
fi

# -------------------------------------------------------
# OS DETECTION
# -------------------------------------------------------
step "1/7" "Detecting operating system"

OS=""
PKG_MANAGER=""

if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS="${ID}"
fi

case "$OS" in
  ubuntu|debian|linuxmint|pop)
    PKG_MANAGER="apt"
    ;;
  amzn|rhel|centos|fedora|rocky|almalinux)
    PKG_MANAGER="yum"
    command -v dnf &>/dev/null && PKG_MANAGER="dnf"
    ;;
  *)
    warn "Unrecognised OS: ${OS}. Attempting to continue..."
    command -v apt-get &>/dev/null && PKG_MANAGER="apt"
    command -v yum     &>/dev/null && PKG_MANAGER="yum"
    command -v dnf     &>/dev/null && PKG_MANAGER="dnf"
    ;;
esac

[ -z "$PKG_MANAGER" ] && die "Cannot detect package manager. Supported: apt, yum, dnf."

success "Detected: ${OS} (${PKG_MANAGER})"

# -------------------------------------------------------
# INSTALL SYSTEM DEPENDENCIES
# -------------------------------------------------------
step "2/7" "Installing system dependencies"

install_packages() {
  case "$PKG_MANAGER" in
    apt)
      apt-get update -qq
      apt-get install -y -qq "$@"
      ;;
    yum|dnf)
      "$PKG_MANAGER" install -y -q "$@"
      ;;
  esac
}

# Python 3.10+ check
PYTHON_BIN=""
for py in python3.12 python3.11 python3.10 python3.9 python3; do
  if command -v "$py" &>/dev/null; then
    PY_VERSION=$("$py" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
    PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
    if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 9 ]; then
      PYTHON_BIN="$py"
      break
    fi
  fi
done

if [ -z "$PYTHON_BIN" ]; then
  info "Installing Python 3.11..."
  case "$PKG_MANAGER" in
    apt) install_packages python3.11 python3.11-venv python3.11-pip ;;
    yum|dnf) install_packages python3.11 ;;
  esac
  PYTHON_BIN="python3.11"
fi

success "Python: $PYTHON_BIN ($("$PYTHON_BIN" --version))"

# Required system packages
info "Installing system packages..."
case "$PKG_MANAGER" in
  apt)
    install_packages \
      python3-venv \
      python3-pip \
      curl \
      nfs-common \
      netcat-openbsd \
      git
    ;;
  yum|dnf)
    install_packages \
      python3-pip \
      curl \
      nfs-utils \
      nmap-ncat \
      git
    ;;
esac

success "System dependencies installed."

# -------------------------------------------------------
# CREATE INSTALL DIRECTORY
# -------------------------------------------------------
step "3/7" "Setting up ZettaBrain directory"

mkdir -p "${INSTALL_DIR}"
mkdir -p "${SRC_DIR}"
mkdir -p /mnt/Rag-data
mkdir -p /var/log

success "Directories created."

# -------------------------------------------------------
# CREATE VIRTUAL ENVIRONMENT (hidden from user)
# -------------------------------------------------------
step "4/7" "Creating Python environment"

if [ -d "${VENV_DIR}" ]; then
  info "Existing environment found — upgrading..."
  "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
else
  info "Creating isolated Python environment..."
  "$PYTHON_BIN" -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
fi

VENV_PYTHON="${VENV_DIR}/bin/python3"
VENV_PIP="${VENV_DIR}/bin/pip"

success "Python environment ready."

# -------------------------------------------------------
# INSTALL ZETTABRAIN-RAG
# -------------------------------------------------------
step "5/7" "Installing zettabrain-rag"

info "Downloading and installing zettabrain-rag v${ZETTABRAIN_VERSION}..."

"${VENV_PIP}" install --quiet "zettabrain-rag==${ZETTABRAIN_VERSION}"

if [ $? -ne 0 ]; then
  info "Exact version not available — installing latest..."
  "${VENV_PIP}" install --quiet zettabrain-rag
fi

INSTALLED_VERSION=$("${VENV_DIR}/bin/zettabrain" --version 2>/dev/null || echo "unknown")
success "Installed: ${INSTALLED_VERSION}"

# Deploy bundled scripts from package to /opt/zettabrain/src
info "Deploying RAG scripts to ${SRC_DIR}..."
PKG_SCRIPTS=$(find "${VENV_DIR}" -path "*/zettabrain_rag/scripts" -type d 2>/dev/null | head -1)
if [ -n "$PKG_SCRIPTS" ]; then
  for script in 03_langchain_rag.py 05_ingest_documents.py 01_chromadb_setup.py 02_embeddings_test.py; do
    if [ -f "${PKG_SCRIPTS}/${script}" ]; then
      cp "${PKG_SCRIPTS}/${script}" "${SRC_DIR}/${script}"
      chmod +x "${SRC_DIR}/${script}"
      success "Deployed: ${script}"
    fi
  done
else
  warn "Could not locate package scripts — they will auto-deploy on first CLI run."
fi

# -------------------------------------------------------
# SYMLINK CLI COMMANDS INTO /usr/local/bin
# -------------------------------------------------------
step "6/7" "Registering CLI commands"

for cmd in "${CLI_COMMANDS[@]}"; do
  TARGET="${VENV_DIR}/bin/${cmd}"
  LINK="${BIN_DIR}/${cmd}"

  if [ -f "$TARGET" ]; then
    # Remove old symlink if exists
    rm -f "$LINK"

    # Create wrapper script (more robust than symlink for venv)
    cat > "$LINK" << WRAPPER
#!/bin/bash
source "${VENV_DIR}/bin/activate"
exec "${TARGET}" "\$@"
WRAPPER
    chmod +x "$LINK"
    success "Registered: ${cmd}"
  else
    warn "Command not found in venv: ${cmd}"
  fi
done

# -------------------------------------------------------
# INSTALL OLLAMA
# -------------------------------------------------------
step "7/7" "Installing Ollama"

if command -v ollama &>/dev/null; then
  OLLAMA_VERSION=$(ollama --version 2>/dev/null || echo "unknown")
  info "Ollama already installed: ${OLLAMA_VERSION}"
else
  info "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh >> "$LOG_FILE" 2>&1
  success "Ollama installed."
fi

# Start Ollama service
if systemctl is-active --quiet ollama 2>/dev/null; then
  info "Ollama service already running."
else
  info "Starting Ollama service..."
  systemctl enable ollama >> "$LOG_FILE" 2>&1 || true
  systemctl start  ollama >> "$LOG_FILE" 2>&1 || true
  sleep 3
fi

# Pull models
info "Pulling embedding model: ${OLLAMA_EMBED_MODEL}"
info "(This downloads ~275MB — please wait)"
ollama pull "${OLLAMA_EMBED_MODEL}" 2>&1 | tail -1

echo ""
echo -e "  ${YELLOW}Skipping LLM model pull (${OLLAMA_LLM_MODEL} is 4.9GB)."
echo -e "  Pull it manually when ready:${NC}"
echo -e "  ${CYAN}ollama pull ${OLLAMA_LLM_MODEL}${NC}"

# -------------------------------------------------------
# WRITE SHELL PROFILE (optional convenience)
# -------------------------------------------------------
PROFILE_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
for profile in /root/.bashrc /home/*/.bashrc; do
  [ -f "$profile" ] || continue
  grep -qF "$BIN_DIR" "$profile" 2>/dev/null || echo "$PROFILE_LINE" >> "$profile"
done

# -------------------------------------------------------
# DONE
# -------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         ZettaBrain RAG installed successfully!       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Install dir : ${GREEN}${INSTALL_DIR}${NC}"
echo -e "  Python env  : ${GREEN}${VENV_DIR}${NC}"
echo -e "  Log file    : ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${BOLD}  Next steps:${NC}"
echo ""
echo -e "  1. Pull the LLM model (4.9GB):"
echo -e "     ${CYAN}ollama pull ${OLLAMA_LLM_MODEL}${NC}"
echo ""
echo -e "  2. Mount your NFS document store:"
echo -e "     ${CYAN}sudo zettabrain-setup${NC}"
echo ""
echo -e "  3. Start chatting:"
echo -e "     ${CYAN}zettabrain-chat${NC}"
echo ""

log "Installation completed. Version: ${ZETTABRAIN_VERSION}"
