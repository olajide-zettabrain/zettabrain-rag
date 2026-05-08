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

# ── 1/5 OS detection ─────────────────────────────────────────
step "1/5" "Detecting operating system"

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

# ── 1b/5  EPEL / extras repos (RHEL, CentOS, Amazon Linux) ───────────
case "$OS" in
  rhel|centos|rocky|almalinux)
    _major="${VERSION_ID%%.*}"
    info "Enabling EPEL for RHEL ${_major}..."
    case "$PKG_MANAGER" in
      dnf) dnf install -y \
             "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${_major}.noarch.rpm" \
             >> "$LOG_FILE" 2>&1 \
             || dnf install -y epel-release >> "$LOG_FILE" 2>&1 || true ;;
      yum) yum install -y epel-release >> "$LOG_FILE" 2>&1 || true ;;
    esac
    # CRB / CodeReady Linux Builder — provides build deps on RHEL 8/9
    dnf config-manager --set-enabled crb >> "$LOG_FILE" 2>&1 \
      || subscription-manager repos \
           --enable "codeready-builder-for-rhel-${_major}-x86_64-rpms" \
           >> "$LOG_FILE" 2>&1 || true
    success "EPEL configured."
    ;;
  amzn)
    if [ "${VERSION_ID}" = "2" ]; then
      info "Amazon Linux 2 — enabling EPEL and Python 3.8 extras..."
      amazon-linux-extras install -y epel python3.8 >> "$LOG_FILE" 2>&1 || true
    fi
    # Amazon Linux 2023 has its own maintained repos — no EPEL needed
    ;;
esac

# ── 2/5 System dependencies ──────────────────────────────────
step "2/5" "Installing system dependencies"

_pkg() {
  case "$PKG_MANAGER" in
    apt)     apt-get install -y -qq "$@" >> "$LOG_FILE" 2>&1 ;;
    yum|dnf) "$PKG_MANAGER" install -y -q "$@" >> "$LOG_FILE" 2>&1 ;;
  esac
}

# Find Python 3.9+
PYTHON_BIN=""
for py in python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
  if command -v "$py" &>/dev/null; then
    PY_NUM=$("$py" -c "import sys; print(sys.version_info.major*10+sys.version_info.minor)" 2>/dev/null || echo 0)
    if [ "$PY_NUM" -ge 39 ] 2>/dev/null; then
      PYTHON_BIN="$py"; break
    fi
  fi
done

if [ -z "$PYTHON_BIN" ]; then
  info "Installing Python 3.11..."
  case "$PKG_MANAGER" in
    apt)
      apt-get update -qq >> "$LOG_FILE" 2>&1
      _pkg python3.11 python3.11-venv python3-pip
      ;;
    dnf)
      # RHEL 9 / AL2023: direct install; RHEL 8: enable module stream first
      dnf install -y python3.11 >> "$LOG_FILE" 2>&1 \
        || { dnf module enable -y python311 >> "$LOG_FILE" 2>&1 || true
             dnf install -y python311 >> "$LOG_FILE" 2>&1 || true; }
      ;;
    yum)
      # Amazon Linux 2: amazon-linux-extras handled above; try python3 fallback
      yum install -y python3 >> "$LOG_FILE" 2>&1 || true
      ;;
  esac
  for py in python3.11 python3.8 python3; do
    command -v "$py" &>/dev/null && { PYTHON_BIN="$py"; break; }
  done
  [ -z "$PYTHON_BIN" ] && die "Could not install Python 3.9+. Check log: $LOG_FILE"
fi

success "Python: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

case "$PKG_MANAGER" in
  apt)
    apt-get update -qq >> "$LOG_FILE" 2>&1
    _pkg python3-pip python3-venv curl git
    ;;
  yum|dnf)
    _pkg python3-pip curl git
    ;;
esac

success "System dependencies installed."

# ── 3/5 NVIDIA drivers ───────────────────────────────────────
step "3/5" "Installing NVIDIA drivers"

# Ensure pciutils is available for hardware detection
_pkg pciutils 2>/dev/null || true

if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null 2>&1; then
  _gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  success "NVIDIA drivers already active: ${_gpu_name}"
elif ! lspci 2>/dev/null | grep -qi nvidia; then
  success "No NVIDIA GPU detected — skipping driver install."
else
  info "NVIDIA GPU detected — installing drivers..."
  _nvidia_reboot=false

  case "$PKG_MANAGER" in
    apt)
      # Ubuntu / Debian — ubuntu-drivers autoinstall picks the correct version
      apt-get install -y -qq "linux-headers-$(uname -r)" 2>/dev/null \
        || apt-get install -y -qq linux-headers-generic >> "$LOG_FILE" 2>&1 || true
      apt-get install -y -qq ubuntu-drivers-common >> "$LOG_FILE" 2>&1 || true

      if command -v ubuntu-drivers &>/dev/null; then
        info "Running ubuntu-drivers autoinstall (this may take a few minutes)..."
        ubuntu-drivers autoinstall >> "$LOG_FILE" 2>&1 \
          || apt-get install -y -qq nvidia-driver-535-server >> "$LOG_FILE" 2>&1 || true
      else
        apt-get install -y -qq nvidia-driver-535-server >> "$LOG_FILE" 2>&1 || true
      fi
      _nvidia_reboot=true
      ;;

    yum|dnf)
      # Amazon Linux / RHEL / CentOS / Fedora — use NVIDIA CUDA repo
      _os_id="" _os_ver=""
      [ -f /etc/os-release ] && { . /etc/os-release; _os_id="${ID}"; _os_ver="${VERSION_ID}"; }

      # Kernel headers + dkms (needed for DKMS driver build)
      "$PKG_MANAGER" install -y "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)" \
        >> "$LOG_FILE" 2>&1 \
        || "$PKG_MANAGER" install -y kernel-devel kernel-headers >> "$LOG_FILE" 2>&1 || true
      "$PKG_MANAGER" install -y dkms >> "$LOG_FILE" 2>&1 || true

      _cuda_repo=""
      case "${_os_id}" in
        amzn)
          case "${_os_ver}" in
            2)    _cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-rhel7.repo" ;;
            202*) _cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo" ;;
          esac ;;
        rhel|centos|rocky|almalinux)
          _major="${_os_ver%%.*}"
          _cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/rhel${_major}/x86_64/cuda-rhel${_major}.repo" ;;
        fedora)
          _cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/fedora${_os_ver}/x86_64/cuda-fedora${_os_ver}.repo" ;;
      esac

      if [ -n "$_cuda_repo" ]; then
        info "Adding NVIDIA CUDA repository..."
        _major="${_os_ver%%.*}"
        # DNF5 (RHEL 10+) dropped config-manager --add-repo; download repo file directly
        curl -fsSL "$_cuda_repo" -o /etc/yum.repos.d/cuda-nvidia.repo >> "$LOG_FILE" 2>&1 || true
        "$PKG_MANAGER" clean expire-cache >> "$LOG_FILE" 2>&1 || true
        info "Installing cuda-drivers (this may take several minutes)..."
        if [ "${_major}" -ge 10 ] 2>/dev/null; then
          # RHEL 10 / DNF5 — module streams deprecated; use --nobest --skip-broken
          "$PKG_MANAGER" install -y cuda-drivers --nobest --skip-broken >> "$LOG_FILE" 2>&1 || true
        elif command -v dnf &>/dev/null; then
          dnf module install -y "nvidia-driver:latest-dkms" >> "$LOG_FILE" 2>&1 \
            || dnf install -y cuda-drivers >> "$LOG_FILE" 2>&1 || true
        else
          yum install -y cuda-drivers >> "$LOG_FILE" 2>&1 || true
        fi
      else
        warn "Unrecognised OS (${_os_id} ${_os_ver}) — skipping NVIDIA repo setup."
        warn "Install drivers manually: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/"
      fi
      _nvidia_reboot=true
      ;;
  esac

  # Attempt to load the kernel module so Ollama (installed next) sees the GPU
  modprobe nvidia >> "$LOG_FILE" 2>&1 || true
  sleep 2

  if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null 2>&1; then
    _gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    success "NVIDIA drivers active — GPU detected: ${_gpu_name}"
  elif $_nvidia_reboot; then
    warn "NVIDIA drivers installed — a reboot is required to activate the kernel module."
    warn "After reboot, Ollama will detect the GPU automatically."
    warn "  → Installation continues; Ollama will run on CPU until you reboot."
  else
    warn "NVIDIA driver installation may not have completed. Check: ${LOG_FILE}"
  fi
fi

# ── 4/5 Install ZettaBrain RAG via pipx ──────────────────────
step "4/5" "Installing ZettaBrain RAG"

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

# Install or upgrade — always bypass pip cache so we get the true latest from PyPI
# (pip cache can serve a stale wheel, requiring two runs to get a new release)
echo ""
if pipx list 2>/dev/null | grep -q "zettabrain-rag"; then
  info "Upgrading zettabrain-rag (downloading latest + dependencies)..."
  echo "  (This can take 2-5 minutes on first upgrade — please wait)"
  echo ""
  pipx upgrade --pip-args='--no-cache-dir' zettabrain-rag 2>&1 | sed 's/^/  /'
else
  info "Installing zettabrain-rag (downloading package + dependencies)..."
  echo "  (This can take 3-6 minutes — please wait)"
  echo ""
  pipx install --pip-args='--no-cache-dir' zettabrain-rag 2>&1 | sed 's/^/  /'
fi

# ── Make CLI commands globally available ─────────────────────
# pipx installs to ~/.local/bin which may not be in PATH (common on servers
# and in sudo shells). Symlink every command into /usr/local/bin which is
# always present, so `zettabrain-setup` works immediately without PATH changes.
PIPX_BIN="$HOME/.local/bin"
export PATH="$PIPX_BIN:/usr/local/bin:$PATH"
hash -r 2>/dev/null || true

_ZB_CMDS=(zettabrain zettabrain-setup zettabrain-chat zettabrain-ingest \
           zettabrain-server zettabrain-status zettabrain-storage zettabrain-cert \
           zettabrain-postinstall)

for _cmd in "${_ZB_CMDS[@]}"; do
  _src="${PIPX_BIN}/${_cmd}"
  if [ -f "$_src" ]; then
    ln -sf "$_src" "/usr/local/bin/${_cmd}"
  fi
done

# Run the postinstall command via full path — refreshes symlinks for any new
# commands added in this version, works even if PATH is not yet updated.
if [ -f "${PIPX_BIN}/zettabrain-postinstall" ]; then
  "${PIPX_BIN}/zettabrain-postinstall" 2>/dev/null || true
fi

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

# ── 5/5 Install Ollama ───────────────────────────────────────
step "5/5" "Installing Ollama + embedding model"

if command -v ollama &>/dev/null; then
  info "Ollama already installed: $(ollama --version 2>/dev/null | head -1)"
else
  # zstd is required by Ollama's installer for archive extraction.
  # Install it explicitly per distro so the output is visible and errors surface.
  if ! command -v zstd &>/dev/null; then
    info "Installing zstd (required by Ollama)..."
    case "$PKG_MANAGER" in
      apt)
        apt-get update -qq 2>&1 | sed 's/^/  /' || true
        apt-get install -y zstd 2>&1 | sed 's/^/  /' || true
        ;;
      dnf)
        dnf install -y zstd 2>&1 | sed 's/^/  /' || true
        ;;
      yum)
        yum install -y zstd 2>&1 | sed 's/^/  /' || true
        ;;
    esac
    # Abort now rather than let Ollama fail mid-extraction
    if ! command -v zstd &>/dev/null; then
      die "zstd could not be installed. Run manually: sudo ${PKG_MANAGER} install zstd — then re-run this installer."
    fi
    success "zstd installed."
  fi
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
