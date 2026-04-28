#!/bin/bash
# ============================================================
# ZettaBrain — NFS Mount Setup  v0.1.9
# ============================================================
# SOURCE OF TRUTH: zettabrain_rag/scripts/nfs_setup.sh
# DO NOT EDIT the root nfs_setup.sh — it is auto-copied
# during build from this file.
# ============================================================
# Steps:
#   1. Install NFS client
#   2. Test NFS connectivity (nc port 2049)
#   3. Create local mount point
#   4. Mount NFS share + persist in /etc/fstab
#   5. Install Ollama + pull required models
#   6. Build RAG vector store
# ============================================================

set -e

# -------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------
MOUNT_POINT="/mnt/Rag-data"
FSTAB_FILE="/etc/fstab"
LOG_FILE="/var/log/zettabrain-nfs-setup.log"
NFS_OPTS="defaults,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"
DEPLOY_DIR="/opt/zettabrain/src"
CONFIG_FILE="${DEPLOY_DIR}/nfs_config.env"
RAG_SCRIPT="${DEPLOY_DIR}/03_langchain_rag.py"
OLLAMA_URL="http://localhost:11434"
EMBED_MODEL="nomic-embed-text"

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
info()    { echo -e "${CYAN}[INFO]${NC}  $*";  log "INFO  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; log "OK    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; log "WARN  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; log "ERROR $*"; }
step()    { echo ""; echo -e "${CYAN}─── $* ${NC}"; }

# -------------------------------------------------------
# ROOT CHECK
# -------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  error "This script must be run as root."
  error "Try: sudo zettabrain-setup"
  exit 1
fi

# -------------------------------------------------------
# BANNER
# -------------------------------------------------------
clear 2>/dev/null || true
echo ""
echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}${BOLD}║          ZettaBrain — NFS Storage Setup              ║${NC}"
echo -e "${BLUE}${BOLD}║     Connect your document store to the RAG server    ║${NC}"
echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# -------------------------------------------------------
# COLLECT NFS DETAILS
# -------------------------------------------------------
echo -e "${CYAN}─── NFS Server Details ──────────────────────────────────${NC}"
echo ""

while true; do
  read -rp "  Enter NFS Server IP address: " NFS_SERVER_IP
  if [[ $NFS_SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    break
  else
    warn "Invalid IP format. Example: 192.168.1.100"
  fi
done

while true; do
  read -rp "  Enter NFS export path on server (e.g. /exports/rag-data): " NFS_EXPORT_PATH
  if [[ $NFS_EXPORT_PATH == /* ]]; then
    break
  else
    warn "Path must start with /. Example: /exports/rag-data"
  fi
done

echo ""
echo -e "  Default local mount point: ${GREEN}${MOUNT_POINT}${NC}"
read -rp "  Use this path? [Y/n]: " CONFIRM_MOUNT
if [[ $CONFIRM_MOUNT =~ ^[Nn]$ ]]; then
  read -rp "  Enter custom mount point: " MOUNT_POINT
  if [[ ! $MOUNT_POINT == /* ]]; then
    error "Mount point must be an absolute path."
    exit 1
  fi
fi

echo ""
echo -e "${CYAN}─── Summary ─────────────────────────────────────────────${NC}"
echo -e "  NFS Server  : ${GREEN}${NFS_SERVER_IP}${NC}"
echo -e "  Export Path : ${GREEN}${NFS_EXPORT_PATH}${NC}"
echo -e "  Mount Point : ${GREEN}${MOUNT_POINT}${NC}"
echo ""
read -rp "  Proceed? [Y/n]: " CONFIRM
if [[ $CONFIRM =~ ^[Nn]$ ]]; then
  info "Setup cancelled."
  exit 0
fi

# -------------------------------------------------------
# STEP 1/6 — INSTALL NFS CLIENT
# -------------------------------------------------------
step "Step 1/6: Installing NFS client ────────────────────"

if command -v apt-get &>/dev/null; then
  info "Detected apt — installing nfs-common + netcat..."
  apt-get update -qq
  apt-get install -y -qq nfs-common netcat-openbsd
elif command -v yum &>/dev/null; then
  info "Detected yum — installing nfs-utils..."
  yum install -y -q nfs-utils nmap-ncat
elif command -v dnf &>/dev/null; then
  info "Detected dnf — installing nfs-utils..."
  dnf install -y -q nfs-utils nmap-ncat
else
  warn "Cannot detect package manager — assuming NFS client is installed."
fi
success "NFS client ready."

# -------------------------------------------------------
# STEP 2/6 — TEST CONNECTIVITY
# -------------------------------------------------------
step "Step 2/6: Testing NFS connectivity ────────────────"

info "Testing port 2049 on ${NFS_SERVER_IP}..."
if command -v nc &>/dev/null; then
  if nc -zw5 "$NFS_SERVER_IP" 2049 &>/dev/null; then
    success "NFS port 2049 is open — server is reachable."
  else
    error "Cannot reach port 2049 on ${NFS_SERVER_IP}."
    error "Check: AWS security group inbound rules, NFS server firewall."
    exit 1
  fi
else
  warn "netcat not found — skipping port check."
fi

# -------------------------------------------------------
# STEP 3/6 — CREATE AND MOUNT
# -------------------------------------------------------
step "Step 3/6: Mounting NFS share ───────────────────────"

# Create mount point
if [ -d "$MOUNT_POINT" ]; then
  info "Mount point already exists: ${MOUNT_POINT}"
else
  mkdir -p "$MOUNT_POINT"
  success "Created: ${MOUNT_POINT}"
fi

# Unmount if already mounted
if mountpoint -q "$MOUNT_POINT"; then
  warn "Already mounted — unmounting first..."
  umount "$MOUNT_POINT" || true
fi

# Mount the NFS share
info "Mounting ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} → ${MOUNT_POINT}..."
if mount -t nfs -o "$NFS_OPTS" "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$MOUNT_POINT"; then
  FILE_COUNT=$(find "$MOUNT_POINT" -maxdepth 2 -type f 2>/dev/null | wc -l)
  success "Mounted. Files visible: ${FILE_COUNT}"
else
  error "Mount failed."
  error "  - Verify NFS export allows this client IP"
  error "  - Run on NFS server: showmount -e ${NFS_SERVER_IP}"
  exit 1
fi

# Persist in /etc/fstab
FSTAB_ENTRY="${NFS_SERVER_IP}:${NFS_EXPORT_PATH}  ${MOUNT_POINT}  nfs  ${NFS_OPTS}  0  0"
if grep -qF "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$FSTAB_FILE"; then
  warn "fstab entry already exists — skipping."
else
  cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  { echo ""; echo "# ZettaBrain NFS — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$FSTAB_ENTRY"; } >> "$FSTAB_FILE"
  success "Added to /etc/fstab — mount persists after reboot."
fi

# Reload systemd so it picks up the new fstab entry
systemctl daemon-reload 2>/dev/null || true

# -------------------------------------------------------
# STEP 4/6 — INSTALL OLLAMA
# -------------------------------------------------------
step "Step 4/6: Installing Ollama ────────────────────────"

if command -v ollama &>/dev/null; then
  info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
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
  sleep 5
fi

# Verify Ollama responds
RETRIES=0
until curl -s "$OLLAMA_URL" &>/dev/null || [ $RETRIES -ge 10 ]; do
  info "Waiting for Ollama to start... (${RETRIES}/10)"
  sleep 3
  RETRIES=$((RETRIES + 1))
done

if curl -s "$OLLAMA_URL" &>/dev/null; then
  success "Ollama is running at ${OLLAMA_URL}"
else
  error "Ollama did not start in time."
  error "Try manually: systemctl start ollama && curl http://localhost:11434"
  exit 1
fi

# -------------------------------------------------------
# STEP 5/6 — PULL REQUIRED MODELS
# -------------------------------------------------------
step "Step 5/6: Pulling AI models ────────────────────────"

# Embedding model (required — small, ~275MB)
if ollama list 2>/dev/null | grep -q "$EMBED_MODEL"; then
  info "Embedding model already present: ${EMBED_MODEL}"
else
  info "Pulling embedding model: ${EMBED_MODEL} (~275MB)..."
  ollama pull "$EMBED_MODEL"
  success "Embedding model ready: ${EMBED_MODEL}"
fi

# LLM model (optional — large, user may pull separately)
LLM_MODEL="${ZETTABRAIN_LLM_MODEL:-llama3.1:8b}"
if ollama list 2>/dev/null | grep -q "$LLM_MODEL"; then
  info "LLM model already present: ${LLM_MODEL}"
else
  warn "LLM model not found: ${LLM_MODEL}"
  warn "Pull it now (~4.9GB) or after setup:"
  warn "  ollama pull ${LLM_MODEL}"
  read -rp "  Pull LLM model now? [y/N]: " PULL_LLM
  if [[ $PULL_LLM =~ ^[Yy]$ ]]; then
    info "Pulling ${LLM_MODEL} — this may take several minutes..."
    ollama pull "$LLM_MODEL"
    success "LLM model ready: ${LLM_MODEL}"
  else
    warn "Skipped. Run 'ollama pull ${LLM_MODEL}' before using zettabrain-chat."
  fi
fi

# -------------------------------------------------------
# STEP 6/6 — BUILD RAG VECTOR STORE
# -------------------------------------------------------
step "Step 6/6: Building RAG vector store ──────────────"

# Save NFS config for RAG scripts
mkdir -p "$DEPLOY_DIR"
cat > "$CONFIG_FILE" << ENVEOF
# ZettaBrain NFS Configuration — $(date '+%Y-%m-%d %H:%M:%S')
NFS_SERVER_IP="${NFS_SERVER_IP}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH}"
NFS_MOUNT_POINT="${MOUNT_POINT}"
RAG_DATA_PATH="${MOUNT_POINT}"
ENVEOF
success "Config saved: ${CONFIG_FILE}"

# ── Python Detection ──────────────────────────────────
# Strategy: find the Python that actually has langchain installed.
# We try three methods in order of reliability.
PYTHON_BIN=""

# Method 1 — Read the pipx shim to extract the venv path
# The shim at ~/.local/bin/zettabrain-chat contains the venv path
SHIM=$(find /root/.local/bin /home/*/.local/bin \
       -name "zettabrain-chat" -type f 2>/dev/null | head -1)

if [ -n "$SHIM" ] && [ -f "$SHIM" ]; then
  # Extract venv root from shim (line like: VIRTUAL_ENV="/root/.local/share/pipx/venvs/zettabrain-rag")
  VENV_ROOT=$(grep -o '".*venvs/zettabrain-rag"' "$SHIM" 2>/dev/null \
              | tr -d '"' || echo "")

  if [ -z "$VENV_ROOT" ]; then
    # Fallback: derive venv root from shim directory's parent
    SHIM_DIR=$(dirname "$SHIM")
    VENV_ROOT=$(find /root/.local/share/pipx/venvs \
                /home/*/.local/share/pipx/venvs \
                -maxdepth 1 -name "zettabrain-rag" -type d 2>/dev/null | head -1)
  fi

  for py in "${VENV_ROOT}/bin/python3" "${VENV_ROOT}/bin/python"; do
    if [ -f "$py" ] && "$py" -c "import langchain_community" 2>/dev/null; then
      PYTHON_BIN="$py"
      info "Python (via pipx shim): ${PYTHON_BIN}"
      break
    fi
  done
fi

# Method 2 — Search known pipx venv locations directly
if [ -z "$PYTHON_BIN" ]; then
  for venv_root in \
      /root/.local/share/pipx/venvs/zettabrain-rag \
      /opt/zettabrain/venv; do
    for py in \
        "${venv_root}/bin/python3" \
        "${venv_root}/bin/python" \
        "${venv_root}/bin/python3.14" \
        "${venv_root}/bin/python3.12" \
        "${venv_root}/bin/python3.11"; do
      if [ -f "$py" ] && "$py" -c "import langchain_community" 2>/dev/null; then
        PYTHON_BIN="$py"
        info "Python (via venv search): ${PYTHON_BIN}"
        break 2
      fi
    done
  done
fi

# Method 3 — System python with langchain installed
if [ -z "$PYTHON_BIN" ]; then
  for py in python3 python3.14 python3.12 python3.11 python3.10; do
    if command -v "$py" &>/dev/null \
       && "$py" -c "import langchain_community" 2>/dev/null; then
      PYTHON_BIN="$(command -v $py)"
      info "Python (system): ${PYTHON_BIN}"
      break
    fi
  done
fi

# Give up gracefully with a useful manual command
if [ -z "$PYTHON_BIN" ]; then
  warn "Could not auto-detect Python with langchain installed."
  warn "The vector store can be built manually after setup:"
  warn ""
  warn "  # Find your pipx Python:"
  warn "  find /root/.local/share/pipx/venvs/zettabrain-rag -name 'python*' -type f"
  warn ""
  warn "  # Then run:"
  warn "  cd ${DEPLOY_DIR} && <python_path> 03_langchain_rag.py --rebuild"
  warn ""
  warn "Continuing setup without vector store build..."
  DOC_COUNT=0
else
  # Verify RAG script exists
  if [ ! -f "$RAG_SCRIPT" ]; then
    error "RAG script not found: ${RAG_SCRIPT}"
    error "Run: zettabrain-chat --rebuild"
    exit 1
  fi

  # Count documents on NFS
  DOC_COUNT=$(find "$MOUNT_POINT" \
    -type f \( -name "*.pdf" -o -name "*.txt" -o -name "*.docx" -o -name "*.md" \) \
    2>/dev/null | wc -l)

  if [ "$DOC_COUNT" -eq 0 ]; then
    warn "No documents found in ${MOUNT_POINT}."
    warn "Add documents then run: zettabrain-chat --rebuild"
  else
    info "Found ${DOC_COUNT} document(s) — building vector store..."
    echo ""
    cd "$DEPLOY_DIR" || exit 1

    if "$PYTHON_BIN" "$RAG_SCRIPT" --rebuild; then
      echo ""
      success "Vector store built successfully."
      log "RAG rebuild complete. Docs: ${DOC_COUNT}"
    else
      echo ""
      error "RAG rebuild failed. Run manually:"
      error "  cd ${DEPLOY_DIR} && ${PYTHON_BIN} 03_langchain_rag.py --rebuild"
      exit 1
    fi
  fi
fi

# -------------------------------------------------------
# DONE
# -------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         ZettaBrain Setup Complete!                   ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  NFS Share   : ${GREEN}${NFS_SERVER_IP}:${NFS_EXPORT_PATH}${NC}"
echo -e "  Mounted at  : ${GREEN}${MOUNT_POINT}${NC}"
echo -e "  Documents   : ${GREEN}${DOC_COUNT:-0} file(s)${NC}"
echo -e "  Scripts dir : ${GREEN}${DEPLOY_DIR}${NC}"
echo -e "  Config      : ${GREEN}${CONFIG_FILE}${NC}"
echo -e "  Log         : ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${CYAN}─── Next Steps ──────────────────────────────────────────${NC}"
echo ""
echo -e "  Start the GUI    : ${YELLOW}zettabrain-server --port 7860${NC}"
echo -e "  Start chat (CLI) : ${YELLOW}zettabrain-chat${NC}"
echo -e "  Rebuild index    : ${YELLOW}zettabrain-chat --rebuild${NC}"
echo -e "  Check documents  : ${YELLOW}ls -lh ${MOUNT_POINT}${NC}"
echo -e "  Remount (reboot) : ${YELLOW}mount -a${NC}"
echo ""

log "Setup complete. NFS: ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} -> ${MOUNT_POINT} | Docs: ${DOC_COUNT:-0}"
