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
  apt) apt-get update -qq >> "$LOG_FILE" 2>&1; _pkg python3-pip python3-venv pipx curl git ;;
  yum|dnf) _pkg python3-pip curl git ;;
esac

success "System dependencies installed."

# ── 3/4 Install ZettaBrain RAG via pipx ──────────────────────
step "3/4" "Installing ZettaBrain RAG"

# Ensure pipx is available — prefer the apt/system version installed above;
# fall back to pip with --break-system-packages for Ubuntu 23.04+ / Debian 12+
# which block `pip install` into the system Python by default.
_ensure_pipx() {
  # Already on PATH — done
  if command -v pipx &>/dev/null; then return 0; fi

  info "Installing pipx..."

  # Try apt / dnf / yum package first (safest on modern distros)
  case "$PKG_MANAGER" in
    apt)
      if apt-get install -y -qq pipx >> "$LOG_FILE" 2>&1; then
        hash -r 2>/dev/null || true
        command -v pipx &>/dev/null && return 0
      fi ;;
    yum|dnf)
      if "$PKG_MANAGER" install -y -q pipx >> "$LOG_FILE" 2>&1; then
        hash -r 2>/dev/null || true
        command -v pipx &>/dev/null && return 0
      fi ;;
  esac

  # pip fallback — use --break-system-packages to bypass the
  # "externally-managed-environment" guard on Ubuntu 23.04+ / Debian 12+
  info "apt pipx not available — installing via pip..."
  if "$PYTHON_BIN" -m pip install --quiet --break-system-packages --upgrade pipx \
       >> "$LOG_FILE" 2>&1; then
    "$PYTHON_BIN" -m pipx ensurepath >> "$LOG_FILE" 2>&1 || true
    export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
    hash -r 2>/dev/null || true
    command -v pipx &>/dev/null && return 0
  fi

  # Last resort: user-level install without --break-system-packages
  "$PYTHON_BIN" -m pip install --quiet --user --upgrade pipx >> "$LOG_FILE" 2>&1 || true
  "$PYTHON_BIN" -m pipx ensurepath >> "$LOG_FILE" 2>&1 || true
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true
  command -v pipx &>/dev/null || die "Could not install pipx. Check log: $LOG_FILE"
}

_ensure_pipx
success "pipx $(pipx --version 2>/dev/null)"

# Install or upgrade — show live output so the user can see download progress
echo ""
if pipx list 2>/dev/null | grep -q "zettabrain-rag"; then
  info "Upgrading zettabrain-rag (downloading latest + dependencies)..."
  echo "  (This can take 2-5 minutes on first upgrade — please wait)"
  echo ""
  pipx upgrade zettabrain-rag 2>&1 | sed 's/^/  /'
else
  info "Installing zettabrain-rag (downloading package + dependencies)..."
  echo "  (This can take 3-6 minutes — please wait)"
  echo ""
  pipx install zettabrain-rag 2>&1 | sed 's/^/  /'
fi

# ── Make CLI commands globally available ─────────────────────
# pipx installs to ~/.local/bin which may not be in PATH (common on servers
# and in sudo shells). Symlink every command into /usr/local/bin which is
# always present, so `zettabrain-setup` works immediately without PATH changes.
PIPX_BIN="$HOME/.local/bin"
export PATH="$PIPX_BIN:/usr/local/bin:$PATH"
hash -r 2>/dev/null || true

_ZB_CMDS=(zettabrain zettabrain-setup zettabrain-chat zettabrain-ingest \
           zettabrain-server zettabrain-status zettabrain-storage zettabrain-cert)

for _cmd in "${_ZB_CMDS[@]}"; do
  _src="${PIPX_BIN}/${_cmd}"
  if [ -f "$_src" ]; then
    ln -sf "$_src" "/usr/local/bin/${_cmd}"
  fi
done

# Also persist ~/.local/bin in PATH for future interactive sessions
for _profile in /root/.bashrc /root/.profile /root/.bash_profile \
                /home/*/.bashrc /home/*/.profile; do
  [ -f "$_profile" ] || continue
  grep -qF "$PIPX_BIN" "$_profile" 2>/dev/null || \
    echo "export PATH=\"$PIPX_BIN:\$PATH\"" >> "$_profile"
done

INSTALLED_VERSION=$(zettabrain --version 2>/dev/null \
  || pipx list 2>/dev/null | grep -oP 'zettabrain-rag \K[\d.]+' | head -1 \
  || echo "latest")
echo ""
success "ZettaBrain RAG installed: ${INSTALLED_VERSION}"
info  "Commands available globally in /usr/local/bin"

# ── 4/4 Install Ollama ───────────────────────────────────────
step "4/4" "Installing Ollama + embedding model"

if command -v ollama &>/dev/null; then
  info "Ollama already installed: $(ollama --version 2>/dev/null | head -1)"
else
  info "Installing Ollama (downloading ~60MB)..."
  curl -fsSL https://ollama.com/install.sh | sh 2>&1 | sed 's/^/  /'
  success "Ollama installed."
fi

systemctl enable ollama >> "$LOG_FILE" 2>&1 || true
if ! systemctl is-active --quiet ollama 2>/dev/null; then
  info "Starting Ollama service..."
  systemctl start ollama >> "$LOG_FILE" 2>&1 || true
  sleep 3
fi

info "Pulling embedding model: ${EMBED_MODEL} (~275MB)..."
ollama pull "$EMBED_MODEL" 2>&1 | sed 's/^/  /'
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
