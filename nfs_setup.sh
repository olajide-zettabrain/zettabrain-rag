#!/bin/bash
# ============================================================
# ZettaBrain — NFS Mount Setup
# Prompts user for NFS server details, mounts the share,
# and validates the RAG data path is accessible.
# ============================================================

set -e

MOUNT_POINT="/mnt/Rag-data"
FSTAB_FILE="/etc/fstab"
LOG_FILE="/var/log/zettabrain-nfs-setup.log"
NFS_OPTS="defaults,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"

# -------------------------------------------------------
# COLOURS
# -------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; log "INFO  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; log "OK    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; log "WARN  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; log "ERROR $*"; }

# -------------------------------------------------------
# MUST RUN AS ROOT
# -------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  error "This script must be run as root. Try: sudo $0"
  exit 1
fi

# -------------------------------------------------------
# BANNER
# -------------------------------------------------------
clear
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          ZettaBrain — NFS Storage Setup              ║${NC}"
echo -e "${BLUE}║     Connect your document store to the RAG server    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# -------------------------------------------------------
# STEP 1 — COLLECT NFS DETAILS
# -------------------------------------------------------
echo -e "${CYAN}─── NFS Server Details ──────────────────────────────────${NC}"
echo ""

# NFS Server IP
while true; do
  read -rp "  Enter NFS Server IP address: " NFS_SERVER_IP
  # Basic IP format validation
  if [[ $NFS_SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    break
  else
    warn "Invalid IP format. Example: 192.168.1.100"
  fi
done

# NFS Export Path
while true; do
  read -rp "  Enter NFS export path on server (e.g. /exports/rag-data): " NFS_EXPORT_PATH
  if [[ $NFS_EXPORT_PATH == /* ]]; then
    break
  else
    warn "Path must start with /. Example: /exports/rag-data"
  fi
done

# Confirm mount point
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
echo -e "  NFS Options : ${GREEN}${NFS_OPTS}${NC}"
echo ""
read -rp "  Proceed with this configuration? [Y/n]: " CONFIRM
if [[ $CONFIRM =~ ^[Nn]$ ]]; then
  info "Setup cancelled by user."
  exit 0
fi

echo ""

# -------------------------------------------------------
# STEP 2 — INSTALL NFS CLIENT
# -------------------------------------------------------
echo -e "${CYAN}─── Step 1/5: Installing NFS client ─────────────────────${NC}"

if command -v apt-get &>/dev/null; then
  # Debian / Ubuntu
  info "Detected apt — installing nfs-common..."
  apt-get update -qq && apt-get install -y -qq nfs-common
elif command -v yum &>/dev/null; then
  # Amazon Linux / RHEL / CentOS
  info "Detected yum — installing nfs-utils..."
  yum install -y -q nfs-utils
elif command -v dnf &>/dev/null; then
  info "Detected dnf — installing nfs-utils..."
  dnf install -y -q nfs-utils
else
  warn "Could not detect package manager. Assuming NFS client is already installed."
fi

success "NFS client ready."

# -------------------------------------------------------
# STEP 3 — PING NFS SERVER
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 2/5: Testing connectivity to NFS server ────────${NC}"

# Use nc (netcat) as the primary connectivity check — more reliable than
# ping on AWS where ICMP is commonly blocked by security groups
info "Testing NFS port 2049 on ${NFS_SERVER_IP}..."

if command -v nc &>/dev/null; then
  if nc -zw5 "$NFS_SERVER_IP" 2049 &>/dev/null; then
    success "NFS port 2049 is open on ${NFS_SERVER_IP} — server is reachable."
  else
    error "Cannot reach NFS port 2049 on ${NFS_SERVER_IP}."
    error "Check: security group inbound rules, NFS server firewall, and that"
    error "the NFS service is running on the server (systemctl status nfs-server)."
    exit 1
  fi
else
  # nc not available — fall back to ping as last resort
  warn "netcat (nc) not found — falling back to ping test."
  if ping -c 2 -W 3 "$NFS_SERVER_IP" &>/dev/null; then
    success "NFS server ${NFS_SERVER_IP} responds to ping (port check skipped)."
  else
    error "Cannot reach NFS server at ${NFS_SERVER_IP} via ping or port check."
    error "Install netcat for a more reliable test: apt-get install -y netcat-openbsd"
    exit 1
  fi
fi

# -------------------------------------------------------
# STEP 4 — CREATE MOUNT POINT
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 3/5: Creating mount point ──────────────────────${NC}"

if [ -d "$MOUNT_POINT" ]; then
  info "Mount point already exists: ${MOUNT_POINT}"
else
  mkdir -p "$MOUNT_POINT"
  success "Created mount point: ${MOUNT_POINT}"
fi

# -------------------------------------------------------
# STEP 5 — MOUNT THE NFS SHARE
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 4/5: Mounting NFS share ────────────────────────${NC}"

# Unmount first if already mounted (clean remount)
if mountpoint -q "$MOUNT_POINT"; then
  warn "Something is already mounted at ${MOUNT_POINT} — unmounting first..."
  umount "$MOUNT_POINT"
fi

info "Mounting ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} → ${MOUNT_POINT}..."

if mount -t nfs -o "$NFS_OPTS" "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$MOUNT_POINT"; then
  success "NFS share mounted successfully."
else
  error "Mount failed. Common causes:"
  error "  - NFS export not configured on server for this client IP"
  error "  - Wrong export path (check: showmount -e ${NFS_SERVER_IP})"
  error "  - Firewall blocking port 2049"
  exit 1
fi

# Verify mount is accessible
if mountpoint -q "$MOUNT_POINT"; then
  FILE_COUNT=$(find "$MOUNT_POINT" -maxdepth 2 -type f 2>/dev/null | wc -l)
  success "Mount point is active. Files visible: ${FILE_COUNT}"
else
  error "Mount point check failed even after successful mount command."
  exit 1
fi

# -------------------------------------------------------
# STEP 6 — PERSIST IN /etc/fstab
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 5/5: Persisting mount in /etc/fstab ────────────${NC}"

FSTAB_ENTRY="${NFS_SERVER_IP}:${NFS_EXPORT_PATH}  ${MOUNT_POINT}  nfs  ${NFS_OPTS}  0  0"

# Check if entry already exists
if grep -qF "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$FSTAB_FILE"; then
  warn "An entry for ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} already exists in /etc/fstab — skipping."
else
  # Backup fstab before editing
  cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  echo "" >> "$FSTAB_FILE"
  echo "# ZettaBrain NFS mount — added $(date '+%Y-%m-%d %H:%M:%S')" >> "$FSTAB_FILE"
  echo "$FSTAB_ENTRY" >> "$FSTAB_FILE"
  success "Added to /etc/fstab — mount will persist after reboot."
fi

# Validate fstab is not broken
if mount -a --fake &>/dev/null; then
  success "fstab validation passed."
else
  warn "fstab validation returned a warning — check /etc/fstab manually."
fi

# -------------------------------------------------------
# STEP 7 — SAVE CONFIG FOR RAG SCRIPTS
# -------------------------------------------------------
CONFIG_FILE="/zettabrain/src/nfs_config.env"
mkdir -p "$(dirname "$CONFIG_FILE")"

cat > "$CONFIG_FILE" << EOF
# ZettaBrain NFS Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
NFS_SERVER_IP="${NFS_SERVER_IP}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH}"
NFS_MOUNT_POINT="${MOUNT_POINT}"
RAG_DATA_PATH="${MOUNT_POINT}"
EOF

success "Config saved to: ${CONFIG_FILE}"

# -------------------------------------------------------
# STEP 8 — TRIGGER RAG VECTOR STORE REBUILD
# -------------------------------------------------------
echo ""
echo -e "${CYAN}─── Step 6/6: Building RAG vector store ─────────────────${NC}"

RAG_SCRIPT="/zettabrain/src/03_langchain_rag.py"
VENV_PYTHON="/zettabrain/src/zettabrain-rag/bin/python3"

# Resolve which python3 to use
if [ -f "$VENV_PYTHON" ]; then
  PYTHON_BIN="$VENV_PYTHON"
  info "Using virtual environment: ${VENV_PYTHON}"
elif command -v python3 &>/dev/null; then
  PYTHON_BIN="python3"
  info "Using system python3: $(which python3)"
else
  error "python3 not found. Cannot trigger RAG rebuild."
  error "Activate your virtual environment and run manually:"
  error "  cd /zettabrain/src && python3 03_langchain_rag.py --rebuild"
  exit 1
fi

# Check RAG script exists
if [ ! -f "$RAG_SCRIPT" ]; then
  error "RAG script not found at: ${RAG_SCRIPT}"
  error "Run manually once script is in place:"
  error "  cd /zettabrain/src && python3 03_langchain_rag.py --rebuild"
  exit 1
fi

# Count files on NFS mount before triggering rebuild
DOC_COUNT=$(find "$MOUNT_POINT" -type f \( -name "*.pdf" -o -name "*.txt" -o -name "*.docx" \) 2>/dev/null | wc -l)

if [ "$DOC_COUNT" -eq 0 ]; then
  warn "No documents found in ${MOUNT_POINT} (*.pdf, *.txt, *.docx)."
  warn "Add your documents to the NFS share first, then run:"
  warn "  cd /zettabrain/src && python3 03_langchain_rag.py --rebuild"
else
  info "Found ${DOC_COUNT} document(s) in ${MOUNT_POINT} — starting RAG rebuild..."
  info "This may take several minutes depending on document count."
  echo ""

  cd /zettabrain/src || exit 1

  # Run rebuild — output streams live to terminal
  if "$PYTHON_BIN" "$RAG_SCRIPT" --rebuild; then
    echo ""
    success "RAG vector store rebuilt successfully."
    log "RAG rebuild completed. Documents: ${DOC_COUNT}"
  else
    echo ""
    error "RAG rebuild failed. Check the output above for details."
    error "Once resolved, re-run manually:"
    error "  cd /zettabrain/src && python3 03_langchain_rag.py --rebuild"
    log "RAG rebuild failed."
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
echo -e "  NFS Share    : ${GREEN}${NFS_SERVER_IP}:${NFS_EXPORT_PATH}${NC}"
echo -e "  Mounted at   : ${GREEN}${MOUNT_POINT}${NC}"
echo -e "  Documents    : ${GREEN}${DOC_COUNT} file(s)${NC}"
echo -e "  Config file  : ${GREEN}${CONFIG_FILE}${NC}"
echo -e "  Log file     : ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${CYAN}─── Useful Commands ─────────────────────────────────────${NC}"
echo ""
echo -e "  Start RAG chat:"
echo -e "     ${YELLOW}cd /zettabrain/src && python3 03_langchain_rag.py${NC}"
echo ""
echo -e "  Rebuild after adding new documents:"
echo -e "     ${YELLOW}cd /zettabrain/src && python3 03_langchain_rag.py --rebuild${NC}"
echo ""
echo -e "  Check mounted files:"
echo -e "     ${YELLOW}ls -lh ${MOUNT_POINT}${NC}"
echo ""
echo -e "  Remount after reboot (auto via fstab):"
echo -e "     ${YELLOW}mount -a${NC}"
echo ""
echo -e "  Unmount:"
echo -e "     ${YELLOW}umount ${MOUNT_POINT}${NC}"
echo ""

log "Setup completed successfully. NFS: ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} -> ${MOUNT_POINT} | Docs: ${DOC_COUNT}"
