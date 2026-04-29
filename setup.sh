#!/bin/bash
# ============================================================
# ZettaBrain — Initial Setup  v0.2.1
# ============================================================
# SOURCE OF TRUTH: zettabrain_rag/scripts/setup.sh
# DO NOT EDIT root setup.sh — auto-copied during make build.
# ============================================================
# What this script does (run once at install time):
#   1. Select PRIMARY storage type (Local / NFS / SMB)
#   2. Configure and mount that storage
#   3. Install Ollama + pull required AI models
#   4. Generate TLS certificate bound to this server's IPs
#   5. Build the initial RAG vector store
#
# To add MORE storage sources after install:
#   sudo zettabrain-storage add
# ============================================================

# NOTE: do NOT use set -e — we handle errors explicitly
# so partial failures don't kill the whole setup

# -------------------------------------------------------
# CONSTANTS — never change these
# -------------------------------------------------------
DEPLOY_DIR="/opt/zettabrain/src"
CERT_DIR="/opt/zettabrain/certs"
CONFIG_FILE="${DEPLOY_DIR}/zettabrain.env"
STORAGE_CONFIG="${DEPLOY_DIR}/storage.conf"  # tracks all storage sources
RAG_SCRIPT="${DEPLOY_DIR}/03_langchain_rag.py"
LOG_FILE="/var/log/zettabrain-setup.log"
FSTAB_FILE="/etc/fstab"
OLLAMA_URL="http://localhost:11434"
EMBED_MODEL="nomic-embed-text"

# NFS/SMB mount options
NFS_OPTS="defaults,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"
SMB_OPTS="uid=0,gid=0,file_mode=0755,dir_mode=0755,noperm,_netdev"

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
step()    { echo ""; echo -e "${CYAN}─── $*${NC}"; }

# -------------------------------------------------------
# ROOT CHECK
# -------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  error "This script must be run as root."
  error "Try: sudo zettabrain-setup"
  exit 1
fi

mkdir -p "$DEPLOY_DIR" "$CERT_DIR"

# -------------------------------------------------------
# BANNER
# -------------------------------------------------------
clear 2>/dev/null || true
echo ""
echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}${BOLD}║           ZettaBrain — Initial Setup                 ║${NC}"
echo -e "${BLUE}${BOLD}║   Configure your primary document storage            ║${NC}"
echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Additional storage can be added after setup with:"
echo -e "  ${CYAN}sudo zettabrain-storage add${NC}"
echo ""

# -------------------------------------------------------
# STEP 1/5 — SELECT PRIMARY STORAGE TYPE
# -------------------------------------------------------
step "Step 1/5: Select Primary Storage Type"
echo ""
echo -e "  Where are your documents stored?\n"
echo -e "  ${BOLD}1)${NC} Local storage  — documents are on this machine"
echo -e "  ${BOLD}2)${NC} NFS share      — documents on a network file server (Linux/Mac)"
echo -e "  ${BOLD}3)${NC} SMB / CIFS     — documents on a Windows share or Samba"
echo ""

STORAGE_TYPE=""
while true; do
  read -rp "  Select [1/2/3]: " _choice
  case "$_choice" in
    1|local|Local|LOCAL) STORAGE_TYPE="local"; break ;;
    2|nfs|NFS)           STORAGE_TYPE="nfs";   break ;;
    3|smb|SMB|cifs|CIFS) STORAGE_TYPE="smb";   break ;;
    *) warn "Please enter 1, 2, or 3." ;;
  esac
done

success "Primary storage: ${STORAGE_TYPE^^}"

# Variables set by each storage block
PRIMARY_PATH=""      # the resolved local path to documents
STORAGE_LABEL=""     # human-readable label for config

# ================================================================
# ── OPTION 1: LOCAL STORAGE ──────────────────────────────────────
# ================================================================
if [ "$STORAGE_TYPE" = "local" ]; then

  step "Local Storage Configuration"
  echo ""
  echo -e "  Enter the full path to your documents folder on this machine."
  echo -e "  ${CYAN}Examples:${NC}"
  echo -e "    Linux   : /home/user/documents  or  /data/documents"
  echo -e "    macOS   : /Users/username/Documents/ZettaBrain"
  echo -e "    WSL/Win : /mnt/c/Users/username/Documents"
  echo ""

  while true; do
    read -rp "  Documents path: " LOCAL_PATH

    # Reject empty — no hardcoded defaults, user must specify their path
    if [ -z "$LOCAL_PATH" ]; then
      warn "Path cannot be empty. Please enter the full path to your documents folder."
      continue
    fi

    # Expand ~ to home directory
    LOCAL_PATH="${LOCAL_PATH/#\~/$HOME}"

    if [ -d "$LOCAL_PATH" ]; then
      _count=$(find "$LOCAL_PATH" -maxdepth 3 -type f 2>/dev/null | wc -l)
      success "Path exists. Files found: ${_count}"
      PRIMARY_PATH="$LOCAL_PATH"
      break
    else
      warn "Path does not exist: ${LOCAL_PATH}"
      read -rp "  Create it? [Y/n]: " _create
      if [[ ! $_create =~ ^[Nn]$ ]]; then
        if mkdir -p "$LOCAL_PATH"; then
          success "Created: ${LOCAL_PATH}"
          PRIMARY_PATH="$LOCAL_PATH"
          break
        else
          error "Could not create ${LOCAL_PATH} — check permissions and try again."
        fi
      fi
    fi
  done

  STORAGE_LABEL="local:${PRIMARY_PATH}"
  info "Primary storage set to: ${PRIMARY_PATH}"

fi

# ================================================================
# ── OPTION 2: NFS SHARE ──────────────────────────────────────────
# ================================================================
if [ "$STORAGE_TYPE" = "nfs" ]; then

  step "NFS Share Configuration"
  echo ""

  # Install NFS client
  info "Installing NFS client packages..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq nfs-common netcat-openbsd 2>/dev/null
  elif command -v yum &>/dev/null; then
    yum install -y -q nfs-utils nmap-ncat 2>/dev/null
  elif command -v dnf &>/dev/null; then
    dnf install -y -q nfs-utils nmap-ncat 2>/dev/null
  else
    warn "Cannot detect package manager — assuming NFS client is installed."
  fi
  success "NFS client ready."
  echo ""

  # Server IP
  NFS_SERVER_IP=""
  while true; do
    read -rp "  NFS Server IP address: " NFS_SERVER_IP
    if [[ $NFS_SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      break
    else
      warn "Invalid IP format. Example: 192.168.1.100"
    fi
  done

  # Export path
  NFS_EXPORT_PATH=""
  while true; do
    read -rp "  NFS export path on server (e.g. /exports/documents): " NFS_EXPORT_PATH
    if [[ $NFS_EXPORT_PATH == /* ]]; then
      break
    else
      warn "Path must start with /. Example: /exports/documents"
    fi
  done

  # Local mount point
  NFS_MOUNT_POINT="/mnt/zettabrain-nfs"
  echo ""
  read -rp "  Local mount point [${NFS_MOUNT_POINT}]: " _mp
  [ -n "$_mp" ] && NFS_MOUNT_POINT="$_mp"

  # Test port 2049
  echo ""
  info "Testing NFS port 2049 on ${NFS_SERVER_IP}..."
  if command -v nc &>/dev/null; then
    if nc -zw5 "$NFS_SERVER_IP" 2049 &>/dev/null; then
      success "NFS port 2049 is open."
    else
      error "Cannot reach port 2049 on ${NFS_SERVER_IP}."
      error "Check: AWS security group inbound rules, NFS server firewall."
      exit 1
    fi
  else
    warn "netcat not found — skipping port connectivity check."
  fi

  # Create mount point and mount
  mkdir -p "$NFS_MOUNT_POINT"

  # Unmount cleanly if already mounted
  if mountpoint -q "$NFS_MOUNT_POINT" 2>/dev/null; then
    warn "Already mounted at ${NFS_MOUNT_POINT} — unmounting first..."
    umount "$NFS_MOUNT_POINT" 2>/dev/null || true
  fi

  info "Mounting ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} → ${NFS_MOUNT_POINT}..."
  if mount -t nfs -o "$NFS_OPTS" "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$NFS_MOUNT_POINT"; then
    _count=$(find "$NFS_MOUNT_POINT" -maxdepth 2 -type f 2>/dev/null | wc -l)
    success "Mounted. Files visible: ${_count}"
    PRIMARY_PATH="$NFS_MOUNT_POINT"
  else
    error "NFS mount failed."
    error "  - Verify the NFS server exports this path for your client IP"
    error "  - Run on the NFS server: showmount -e ${NFS_SERVER_IP}"
    exit 1
  fi

  # Persist in /etc/fstab
  _fstab_line="${NFS_SERVER_IP}:${NFS_EXPORT_PATH}  ${NFS_MOUNT_POINT}  nfs  ${NFS_OPTS}  0  0"
  if grep -qF "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$FSTAB_FILE" 2>/dev/null; then
    warn "fstab entry already exists — skipping."
  else
    cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    { echo ""; echo "# ZettaBrain NFS — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$_fstab_line"; } >> "$FSTAB_FILE"
    success "Added to /etc/fstab — mount persists after reboot."
  fi
  systemctl daemon-reload 2>/dev/null || true

  STORAGE_LABEL="nfs:${NFS_SERVER_IP}:${NFS_EXPORT_PATH}"

fi

# ================================================================
# ── OPTION 3: SMB / CIFS ─────────────────────────────────────────
# ================================================================
if [ "$STORAGE_TYPE" = "smb" ]; then

  step "SMB / CIFS Share Configuration"
  echo ""

  # Install cifs-utils
  info "Installing SMB client (cifs-utils)..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq cifs-utils netcat-openbsd 2>/dev/null
  elif command -v yum &>/dev/null; then
    yum install -y -q cifs-utils nmap-ncat 2>/dev/null
  elif command -v dnf &>/dev/null; then
    dnf install -y -q cifs-utils nmap-ncat 2>/dev/null
  else
    warn "Cannot detect package manager — assuming cifs-utils is installed."
  fi
  success "SMB client ready."
  echo ""

  # Server IP
  SMB_SERVER_IP=""
  while true; do
    read -rp "  SMB Server IP address: " SMB_SERVER_IP
    if [[ $SMB_SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      break
    else
      warn "Invalid IP format. Example: 192.168.1.50"
    fi
  done

  # Share name
  SMB_SHARE=""
  while true; do
    read -rp "  SMB share name (e.g. documents): " SMB_SHARE
    if [ -n "$SMB_SHARE" ]; then
      break
    else
      warn "Share name cannot be empty."
    fi
  done

  # Credentials
  echo ""
  echo -e "  ${CYAN}Authentication${NC} (leave username blank for guest/anonymous access)"
  read -rp "  Username [blank for guest]: " SMB_USER
  SMB_PASS=""
  SMB_DOMAIN=""
  if [ -n "$SMB_USER" ]; then
    read -rsp "  Password: " SMB_PASS
    echo ""
    read -rp "  Domain   [blank if not required]: " SMB_DOMAIN
  fi

  # Local mount point
  SMB_MOUNT_POINT="/mnt/zettabrain-smb"
  echo ""
  read -rp "  Local mount point [${SMB_MOUNT_POINT}]: " _mp
  [ -n "$_mp" ] && SMB_MOUNT_POINT="$_mp"

  # Test SMB port 445
  echo ""
  info "Testing SMB port 445 on ${SMB_SERVER_IP}..."
  if command -v nc &>/dev/null; then
    if nc -zw5 "$SMB_SERVER_IP" 445 &>/dev/null; then
      success "SMB port 445 is open."
    else
      error "Cannot reach port 445 on ${SMB_SERVER_IP}."
      error "Check: Windows Firewall, security group rules, SMB service status."
      exit 1
    fi
  else
    warn "netcat not found — skipping port check."
  fi

  # Write credentials file (never put passwords in fstab or mount options)
  SMB_CREDS_FILE="/etc/zettabrain/smb-${SMB_SERVER_IP}.credentials"
  mkdir -p /etc/zettabrain
  {
    echo "username=${SMB_USER:-guest}"
    [ -n "$SMB_PASS" ]   && echo "password=${SMB_PASS}"
    [ -n "$SMB_DOMAIN" ] && echo "domain=${SMB_DOMAIN}"
  } > "$SMB_CREDS_FILE"
  chmod 600 "$SMB_CREDS_FILE"
  chown root:root "$SMB_CREDS_FILE"
  success "Credentials saved securely: ${SMB_CREDS_FILE}"

  # Build mount options — reference credentials file, never inline
  _smb_mount_opts="${SMB_OPTS},credentials=${SMB_CREDS_FILE}"

  # Create mount point
  mkdir -p "$SMB_MOUNT_POINT"

  # Unmount if already mounted
  if mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null; then
    warn "Already mounted at ${SMB_MOUNT_POINT} — unmounting first..."
    umount "$SMB_MOUNT_POINT" 2>/dev/null || true
  fi

  # Mount
  info "Mounting //${SMB_SERVER_IP}/${SMB_SHARE} → ${SMB_MOUNT_POINT}..."
  if mount -t cifs "//${SMB_SERVER_IP}/${SMB_SHARE}" "$SMB_MOUNT_POINT" \
     -o "$_smb_mount_opts" 2>/dev/null; then
    _count=$(find "$SMB_MOUNT_POINT" -maxdepth 2 -type f 2>/dev/null | wc -l)
    success "Mounted. Files visible: ${_count}"
    PRIMARY_PATH="$SMB_MOUNT_POINT"
  else
    error "SMB mount failed. Common causes:"
    error "  - Wrong share name (list shares: smbclient -L //${SMB_SERVER_IP} -N)"
    error "  - Wrong credentials"
    error "  - SMB version mismatch — try adding vers=2.0 to SMB_OPTS"
    exit 1
  fi

  # Persist in /etc/fstab — use credentials file reference, not inline password
  _fstab_line="//${SMB_SERVER_IP}/${SMB_SHARE}  ${SMB_MOUNT_POINT}  cifs  ${_smb_mount_opts}  0  0"
  if grep -qF "//${SMB_SERVER_IP}/${SMB_SHARE}" "$FSTAB_FILE" 2>/dev/null; then
    warn "fstab entry already exists — skipping."
  else
    cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    { echo ""; echo "# ZettaBrain SMB — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$_fstab_line"; } >> "$FSTAB_FILE"
    success "Added to /etc/fstab — mount persists after reboot."
  fi
  systemctl daemon-reload 2>/dev/null || true

  STORAGE_LABEL="smb://${SMB_SERVER_IP}/${SMB_SHARE}"

fi

# ================================================================
# STEP 2/5 — INSTALL OLLAMA
# ================================================================
step "Step 2/5: Installing Ollama"

if command -v ollama &>/dev/null; then
  info "Ollama already installed: $(ollama --version 2>/dev/null | head -1)"
else
  info "Downloading and installing Ollama..."
  if curl -fsSL https://ollama.com/install.sh | sh >> "$LOG_FILE" 2>&1; then
    success "Ollama installed."
  else
    error "Ollama installation failed. Check log: ${LOG_FILE}"
    exit 1
  fi
fi

# Ensure service is enabled and running
systemctl enable ollama >> "$LOG_FILE" 2>&1 || true
if systemctl is-active --quiet ollama 2>/dev/null; then
  info "Ollama service already running."
else
  info "Starting Ollama service..."
  systemctl start ollama >> "$LOG_FILE" 2>&1 || true
  sleep 5
fi

# Wait for Ollama API to be ready (up to 60 seconds)
info "Waiting for Ollama API to be ready..."
_retries=0
until curl -s "$OLLAMA_URL" &>/dev/null || [ $_retries -ge 20 ]; do
  sleep 3
  _retries=$((_retries + 1))
done

if curl -s "$OLLAMA_URL" &>/dev/null; then
  success "Ollama API is ready at ${OLLAMA_URL}"
else
  error "Ollama did not start within 60 seconds."
  error "Check: journalctl -u ollama -n 30"
  exit 1
fi

# ================================================================
# STEP 3/5 — PULL AI MODELS
# ================================================================
step "Step 3/5: Pulling required AI models"

# Embedding model — required, small (~275MB)
if ollama list 2>/dev/null | grep -q "^${EMBED_MODEL}"; then
  info "Embedding model already present: ${EMBED_MODEL}"
else
  info "Pulling embedding model: ${EMBED_MODEL} (~275MB)..."
  if ollama pull "$EMBED_MODEL"; then
    success "Embedding model ready: ${EMBED_MODEL}"
  else
    error "Failed to pull ${EMBED_MODEL}. Check internet connection."
    exit 1
  fi
fi

# LLM — large download, ask first
LLM_MODEL="${ZETTABRAIN_LLM_MODEL:-llama3.1:8b}"
if ollama list 2>/dev/null | grep -q "^${LLM_MODEL}"; then
  info "LLM already present: ${LLM_MODEL}"
else
  warn "LLM model not found: ${LLM_MODEL} (~4.9GB)"
  echo ""
  read -rp "  Pull LLM model now? [y/N]: " _pull_llm
  if [[ $_pull_llm =~ ^[Yy]$ ]]; then
    info "Pulling ${LLM_MODEL} — this may take several minutes..."
    if ollama pull "$LLM_MODEL"; then
      success "LLM ready: ${LLM_MODEL}"
    else
      warn "LLM pull failed. Run later: ollama pull ${LLM_MODEL}"
      LLM_MODEL="(not pulled)"
    fi
  else
    warn "Skipped. Run when ready: ollama pull ${LLM_MODEL}"
  fi
fi

# ================================================================
# STEP 4/5 — GENERATE TLS CERTIFICATE
# ================================================================
step "Step 4/5: Generating TLS certificate"

# Install openssl if needed
if ! command -v openssl &>/dev/null; then
  info "Installing openssl..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y -qq openssl 2>/dev/null
  elif command -v yum &>/dev/null; then
    yum install -y -q openssl 2>/dev/null
  elif command -v dnf &>/dev/null; then
    dnf install -y -q openssl 2>/dev/null
  fi
fi

CERT_FILE="${CERT_DIR}/cert.pem"
KEY_FILE="${CERT_DIR}/key.pem"
CERT_CONF="${CERT_DIR}/openssl.cnf"

# Detect this server's IPs and hostname
SERVER_HOST=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")
PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
ALL_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' || echo "127.0.0.1")

info "Certificate will cover:"
info "  Hostname : ${SERVER_HOST}"
info "  IPs      : $(echo $ALL_IPS | tr '\n' ' ')"

# Build Subject Alternative Names list
SAN_LIST="DNS:localhost,DNS:${SERVER_HOST},IP:127.0.0.1"
while IFS= read -r _ip; do
  [ -n "$_ip" ] && [ "$_ip" != "127.0.0.1" ] && SAN_LIST="${SAN_LIST},IP:${_ip}"
done <<< "$ALL_IPS"

# Optionally add extra IPs or domains
echo ""
read -rp "  Add extra IP/domain to certificate? (blank to skip): " _extra
if [ -n "$_extra" ]; then
  if [[ $_extra =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN_LIST="${SAN_LIST},IP:${_extra}"
  else
    SAN_LIST="${SAN_LIST},DNS:${_extra}"
  fi
  info "Added to certificate SAN: ${_extra}"
fi

# Write OpenSSL config
cat > "$CERT_CONF" << SSLEOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C  = US
ST = ZettaBrain
L  = Local
O  = ZettaBrain RAG
OU = Self-Signed
CN = ${SERVER_HOST}

[v3_req]
subjectAltName   = ${SAN_LIST}
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
basicConstraints = critical, CA:false
SSLEOF

# Generate certificate — remove old one if exists
rm -f "$CERT_FILE" "$KEY_FILE"

if openssl req -x509 -nodes \
    -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out    "$CERT_FILE" \
    -days   3650 \
    -config "$CERT_CONF" \
    >> "$LOG_FILE" 2>&1; then

  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"

  FINGERPRINT=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null \
                | sed 's/SHA256 Fingerprint=//')

  success "TLS certificate generated (valid 10 years)."
  info "  Cert : ${CERT_FILE}"
  info "  Key  : ${KEY_FILE}"
  info "  SANs : ${SAN_LIST}"
else
  warn "TLS certificate generation failed — server will run HTTP only."
  warn "Check: ${LOG_FILE}"
  CERT_FILE=""
  KEY_FILE=""
  FINGERPRINT=""
fi

# ================================================================
# SAVE CONFIGURATION
# ================================================================
cat > "$CONFIG_FILE" << ENVEOF
# ZettaBrain Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Re-run 'sudo zettabrain-setup' to regenerate this file.
# Add more storage with: sudo zettabrain-storage add

# --- Primary Storage ---
PRIMARY_STORAGE_TYPE="${STORAGE_TYPE}"
PRIMARY_STORAGE_LABEL="${STORAGE_LABEL}"
PRIMARY_STORAGE_PATH="${PRIMARY_PATH}"
ZETTABRAIN_DOCS="${PRIMARY_PATH}"
RAG_DATA_PATH="${PRIMARY_PATH}"

# --- AI Models ---
OLLAMA_HOST="${OLLAMA_URL}"
ZETTABRAIN_LLM_MODEL="${LLM_MODEL}"
ZETTABRAIN_EMBED_MODEL="${EMBED_MODEL}"

# --- TLS ---
ZETTABRAIN_CERT="${CERT_FILE}"
ZETTABRAIN_KEY="${KEY_FILE}"
ZETTABRAIN_TLS_FINGERPRINT="${FINGERPRINT}"
ZETTABRAIN_SERVER_HOST="${PRIMARY_IP}"
ENVEOF

success "Configuration saved: ${CONFIG_FILE}"

# Write storage registry (tracks primary + any additional sources added later)
cat > "$STORAGE_CONFIG" << STEOF
# ZettaBrain Storage Registry
# Format: TYPE|LABEL|LOCAL_PATH
# Managed by: zettabrain-setup and zettabrain-storage
primary|${STORAGE_TYPE}|${STORAGE_LABEL}|${PRIMARY_PATH}
STEOF

success "Storage registry saved: ${STORAGE_CONFIG}"

# ================================================================
# STEP 5/5 — BUILD RAG VECTOR STORE
# ================================================================
step "Step 5/5: Building RAG vector store"

# Find Python that has langchain installed
PYTHON_BIN=""

# Method 1 — pipx venv (most reliable for pipx installs)
for _venv in \
    /root/.local/share/pipx/venvs/zettabrain-rag \
    /home/*/.local/share/pipx/venvs/zettabrain-rag \
    /opt/zettabrain/venv; do
  for _py in \
      "${_venv}/bin/python3" \
      "${_venv}/bin/python" \
      "${_venv}/bin/python3.14" \
      "${_venv}/bin/python3.13" \
      "${_venv}/bin/python3.12" \
      "${_venv}/bin/python3.11"; do
    if [ -f "$_py" ] && "$_py" -c "import langchain_community" 2>/dev/null; then
      PYTHON_BIN="$_py"
      info "Using Python: ${PYTHON_BIN}"
      break 2
    fi
  done
done

# Method 2 — system Python
if [ -z "$PYTHON_BIN" ]; then
  for _py in python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
    if command -v "$_py" &>/dev/null \
       && "$_py" -c "import langchain_community" 2>/dev/null; then
      PYTHON_BIN="$(command -v $_py)"
      info "Using system Python: ${PYTHON_BIN}"
      break
    fi
  done
fi

DOC_COUNT=0

if [ -z "$PYTHON_BIN" ]; then
  warn "No Python with langchain found. Build the vector store manually:"
  warn "  find /root/.local/share/pipx/venvs/zettabrain-rag -name 'python*' -type f | head -3"
  warn "  <python_path> ${RAG_SCRIPT} --rebuild"

elif [ ! -f "$RAG_SCRIPT" ]; then
  warn "RAG script not deployed yet at: ${RAG_SCRIPT}"
  warn "Run: zettabrain-chat --rebuild"

else
  DOC_COUNT=$(find "$PRIMARY_PATH" \
    -type f \( -name "*.pdf" -o -name "*.txt" -o -name "*.docx" -o -name "*.md" \) \
    2>/dev/null | wc -l)

  if [ "$DOC_COUNT" -eq 0 ]; then
    warn "No documents found in ${PRIMARY_PATH}."
    warn "Add documents then run: zettabrain-ingest --rebuild"
  else
    info "Found ${DOC_COUNT} document(s) — building vector store..."
    echo ""
    cd "$DEPLOY_DIR" || true

    if ZETTABRAIN_DOCS="$PRIMARY_PATH" "$PYTHON_BIN" "$RAG_SCRIPT" --rebuild; then
      echo ""
      success "Vector store built successfully."
      log "RAG build complete. Path: ${PRIMARY_PATH} | Docs: ${DOC_COUNT}"
    else
      echo ""
      warn "RAG build failed. Run manually once documents are in place:"
      warn "  ZETTABRAIN_DOCS=${PRIMARY_PATH} ${PYTHON_BIN} ${RAG_SCRIPT} --rebuild"
    fi
  fi
fi

# ================================================================
# INSTALL SYSTEMD SERVICE FOR WEB SERVER
# ================================================================
step "Installing ZettaBrain as a system service"

_server_bin=$(command -v zettabrain-server 2>/dev/null \
              || echo "/root/.local/bin/zettabrain-server")

cat > /etc/systemd/system/zettabrain.service << SVCEOF
[Unit]
Description=ZettaBrain RAG Web Server
After=network-online.target ollama.service
Wants=network-online.target
Requires=ollama.service

[Service]
Type=simple
User=root
WorkingDirectory=${DEPLOY_DIR}
ExecStart=${_server_bin} --port 7860
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment="PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=-${CONFIG_FILE}

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable zettabrain >> "$LOG_FILE" 2>&1 || true
systemctl restart zettabrain >> "$LOG_FILE" 2>&1 || true
sleep 3

if systemctl is-active --quiet zettabrain 2>/dev/null; then
  success "ZettaBrain web server started and enabled on boot."
else
  warn "Web server did not start automatically."
  warn "Start manually: zettabrain-server --port 7860"
fi

# ================================================================
# DONE
# ================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║        ZettaBrain Setup Complete!  🎉                ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Storage type : ${GREEN}${STORAGE_TYPE^^}${NC}"
echo -e "  Docs path    : ${GREEN}${PRIMARY_PATH}${NC}"
echo -e "  Documents    : ${GREEN}${DOC_COUNT} file(s)${NC}"
echo -e "  TLS cert     : ${GREEN}${CERT_FILE:-HTTP only (no cert)}${NC}"
echo -e "  Config file  : ${GREEN}${CONFIG_FILE}${NC}"
echo ""
echo -e "${CYAN}─── Access the GUI ──────────────────────────────────────${NC}"
echo ""
if [ -n "$CERT_FILE" ]; then
  echo -e "  Open in browser: ${BOLD}https://${PRIMARY_IP}:7860${NC}"
  echo ""
  echo -e "  ${YELLOW}First visit: browser will warn about self-signed certificate."
  echo -e "  Click 'Advanced' → 'Proceed to site' to continue.${NC}"
  echo ""
  echo -e "  Certificate fingerprint (SHA-256) for verification:"
  echo -e "  ${CYAN}${FINGERPRINT}${NC}"
else
  echo -e "  Open in browser: ${BOLD}http://${PRIMARY_IP}:7860${NC}"
fi
echo ""
echo -e "${CYAN}─── Useful Commands ─────────────────────────────────────${NC}"
echo ""
echo -e "  Add more storage  : ${YELLOW}sudo zettabrain-storage add${NC}"
echo -e "  CLI chat          : ${YELLOW}zettabrain-chat${NC}"
echo -e "  Ingest documents  : ${YELLOW}zettabrain-ingest --rebuild${NC}"
echo -e "  Check status      : ${YELLOW}zettabrain-status${NC}"
echo -e "  View server logs  : ${YELLOW}journalctl -u zettabrain -f${NC}"
echo ""

log "Setup complete. Type=${STORAGE_TYPE} Path=${PRIMARY_PATH} Docs=${DOC_COUNT}"
