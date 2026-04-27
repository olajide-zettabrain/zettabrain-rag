#!/bin/bash
# ============================================================
# ZettaBrain — NFS Mount Setup
# Prompts user for NFS server details, mounts the share,
# validates connectivity, and triggers RAG vector store build.
# ============================================================

set -e

MOUNT_POINT="/mnt/Rag-data"
FSTAB_FILE="/etc/fstab"
LOG_FILE="/var/log/zettabrain-nfs-setup.log"
NFS_OPTS="defaults,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"
DEPLOY_DIR="/opt/zettabrain/src"
CONFIG_FILE="${DEPLOY_DIR}/nfs_config.env"
RAG_SCRIPT="${DEPLOY_DIR}/03_langchain_rag.py"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true; }
info()    { echo -e "${CYAN}[INFO]${NC}  $*";  log "INFO  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; log "OK    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; log "WARN  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; log "ERROR $*"; }

if [ "$EUID" -ne 0 ]; then
  error "This script must be run as root. Try: sudo zettabrain-setup"
  exit 1
fi

clear 2>/dev/null || true
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          ZettaBrain — NFS Storage Setup              ║${NC}"
echo -e "${BLUE}║     Connect your document store to the RAG server    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
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
echo ""

# -------------------------------------------------------
# STEP 1/6 — INSTALL NFS CLIENT
# -------------------------------------------------------
echo -e "${CYAN}─── Step 1/6: Installing NFS client ─────────────────────${NC}"

if command -v apt-get &>/dev/null; then
  info "Detected apt — installing nfs-common..."
  apt-get update -qq && apt-get install -y -qq nfs-common netcat-openbsd
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
echo ""
echo -e "${CYAN}─── Step 2/6: Testing connectivity ──────────────────────${NC}"
info "Testing NFS port 2049 on ${NFS_SERVER_IP}..."

if command -v nc &>/dev/null; then
  if nc -zw5 "$NFS_SERVER_IP" 2049 &>/dev/null; then
    success "NFS port 2049 is open — server is reachable."
  else
    error "Cannot reach port 2049 on ${NFS_SERVER_IP}."
    error "Check: security group rules and NFS server firewall."
    exit 1
  fi
else
  warn "netcat not found — skipping port check."
fi

# -------------------------------------------------------
# STEP 3/6 — CREATE MOUNT POINT
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 3/6: Creating mount point ──────────────────────${NC}"

if [ -d "$MOUNT_POINT" ]; then
  info "Mount point already exists: ${MOUNT_POINT}"
else
  mkdir -p "$MOUNT_POINT"
  success "Created: ${MOUNT_POINT}"
fi

# -------------------------------------------------------
# STEP 4/6 — MOUNT NFS SHARE
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 4/6: Mounting NFS share ────────────────────────${NC}"

if mountpoint -q "$MOUNT_POINT"; then
  warn "Already mounted at ${MOUNT_POINT} — unmounting first..."
  umount "$MOUNT_POINT"
fi

info "Mounting ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} → ${MOUNT_POINT}..."

if mount -t nfs -o "$NFS_OPTS" "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$MOUNT_POINT"; then
  FILE_COUNT=$(find "$MOUNT_POINT" -maxdepth 2 -type f 2>/dev/null | wc -l)
  success "Mounted successfully. Files visible: ${FILE_COUNT}"
else
  error "Mount failed."
  error "  - Verify NFS export allows this client IP"
  error "  - Check path with: showmount -e ${NFS_SERVER_IP}"
  exit 1
fi

# -------------------------------------------------------
# STEP 5/6 — PERSIST IN /etc/fstab
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 5/6: Persisting mount in /etc/fstab ────────────${NC}"

FSTAB_ENTRY="${NFS_SERVER_IP}:${NFS_EXPORT_PATH}  ${MOUNT_POINT}  nfs  ${NFS_OPTS}  0  0"

if grep -qF "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$FSTAB_FILE"; then
  warn "Entry already exists in /etc/fstab — skipping."
else
  cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  { echo ""; echo "# ZettaBrain NFS — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$FSTAB_ENTRY"; } >> "$FSTAB_FILE"
  success "Added to /etc/fstab — persists after reboot."
fi

# -------------------------------------------------------
# STEP 6/6 — BUILD RAG VECTOR STORE
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 6/6: Building RAG vector store ─────────────────${NC}"

# Save NFS config
mkdir -p "$DEPLOY_DIR"
cat > "$CONFIG_FILE" << ENVEOF
# ZettaBrain NFS Configuration — $(date '+%Y-%m-%d %H:%M:%S')
NFS_SERVER_IP="${NFS_SERVER_IP}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH}"
NFS_MOUNT_POINT="${MOUNT_POINT}"
RAG_DATA_PATH="${MOUNT_POINT}"
ENVEOF
success "Config saved: ${CONFIG_FILE}"

# Detect Python — must be the one that has langchain packages installed
# Priority: pipx venv → opt venv → system python3
PYTHON_BIN=""

for search_root in \
    /root/.local/share/pipx/venvs/zettabrain-rag \
    /opt/zettabrain/venv; do
  candidate=$(find "$search_root" -name "python3" -type f 2>/dev/null | head -1)
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    if "$candidate" -c "import langchain_community" 2>/dev/null; then
      PYTHON_BIN="$candidate"
      info "Using Python with all packages: ${PYTHON_BIN}"
      break
    fi
  fi
done

if [ -z "$PYTHON_BIN" ]; then
  if command -v python3 &>/dev/null && python3 -c "import langchain_community" 2>/dev/null; then
    PYTHON_BIN="$(command -v python3)"
    info "Using system Python: ${PYTHON_BIN}"
  else
    error "No Python found with langchain packages installed."
    error "Try: pipx upgrade --force zettabrain-rag"
    error "Then re-run: sudo zettabrain-setup"
    exit 1
  fi
fi

# Verify RAG script exists
if [ ! -f "$RAG_SCRIPT" ]; then
  error "RAG script not found at: ${RAG_SCRIPT}"
  error "Run: zettabrain-chat --rebuild"
  exit 1
fi

# Count documents
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
    error "  cd ${DEPLOY_DIR} && python3 03_langchain_rag.py --rebuild"
    exit 1
  fi
fi

# -------------------------------------------------------
# DONE
# -------------------------------------------------------
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ZettaBrain Setup Complete!                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  NFS Share   : ${GREEN}${NFS_SERVER_IP}:${NFS_EXPORT_PATH}${NC}"
echo -e "  Mounted at  : ${GREEN}${MOUNT_POINT}${NC}"
echo -e "  Documents   : ${GREEN}${DOC_COUNT} file(s)${NC}"
echo -e "  Scripts dir : ${GREEN}${DEPLOY_DIR}${NC}"
echo -e "  Config      : ${GREEN}${CONFIG_FILE}${NC}"
echo -e "  Log         : ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${CYAN}─── Useful Commands ─────────────────────────────────────${NC}"
echo ""
echo -e "  Start chatting  : ${YELLOW}zettabrain-chat${NC}"
echo -e "  Rebuild index   : ${YELLOW}zettabrain-chat --rebuild${NC}"
echo -e "  Check documents : ${YELLOW}ls -lh ${MOUNT_POINT}${NC}"
echo -e "  Remount (reboot): ${YELLOW}mount -a${NC}"
echo ""

log "Setup complete. NFS: ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} -> ${MOUNT_POINT}"
