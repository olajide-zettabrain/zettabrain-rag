#!/bin/bash
# ============================================================
# ZettaBrain — Storage Setup  v0.2.0
# ============================================================
# SOURCE OF TRUTH: zettabrain_rag/scripts/setup.sh
# DO NOT EDIT the root setup.sh — auto-copied during build.
# ============================================================
# Steps:
#   1. Select storage type (Local / NFS / SMB)
#   2. Configure and mount selected storage
#   3. Install Ollama + pull required models
#   4. Generate TLS certificate for secure GUI
#   5. Build RAG vector store
# ============================================================

set -e

# -------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------
MOUNT_POINT="/mnt/Rag-data"
FSTAB_FILE="/etc/fstab"
LOG_FILE="/var/log/zettabrain-setup.log"
DEPLOY_DIR="/opt/zettabrain/src"
CERT_DIR="/opt/zettabrain/certs"
CONFIG_FILE="${DEPLOY_DIR}/zettabrain.env"
RAG_SCRIPT="${DEPLOY_DIR}/03_langchain_rag.py"
OLLAMA_URL="http://localhost:11434"
EMBED_MODEL="nomic-embed-text"

# NFS mount options
NFS_OPTS="defaults,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"

# SMB mount options
SMB_OPTS="uid=0,gid=0,file_mode=0755,dir_mode=0755,noperm"

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
ask()     { echo -e "${YELLOW}  ?${NC}  $*"; }

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
echo -e "${BLUE}${BOLD}║           ZettaBrain — Storage Setup                 ║${NC}"
echo -e "${BLUE}${BOLD}║   Configure where your documents are stored          ║${NC}"
echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# -------------------------------------------------------
# STEP 1/5 — SELECT STORAGE TYPE
# -------------------------------------------------------
step "Step 1/5: Select Storage Type ──────────────────────"
echo ""
echo -e "  How are your documents stored?\n"
echo -e "  ${BOLD}1)${NC} Local storage  — documents are on this machine"
echo -e "  ${BOLD}2)${NC} NFS share      — documents are on a network file server"
echo -e "  ${BOLD}3)${NC} SMB / CIFS     — documents are on a Windows share or Samba"
echo ""

while true; do
  read -rp "  Select option [1/2/3]: " STORAGE_TYPE
  case "$STORAGE_TYPE" in
    1|local|Local|LOCAL) STORAGE_TYPE="local"; break ;;
    2|nfs|NFS)           STORAGE_TYPE="nfs";   break ;;
    3|smb|SMB|cifs|CIFS) STORAGE_TYPE="smb";   break ;;
    *) warn "Please enter 1, 2, or 3." ;;
  esac
done

success "Storage type selected: ${STORAGE_TYPE^^}"

# -------------------------------------------------------
# STORAGE CONFIGURATION BY TYPE
# -------------------------------------------------------

STORAGE_LABEL=""
FSTAB_ENTRY=""

# ── LOCAL ──────────────────────────────────────────────
if [ "$STORAGE_TYPE" = "local" ]; then

  step "Local Storage Configuration ──────────────────────"
  echo ""

  # Detect OS for default path suggestions
  if [[ "$OSTYPE" == "darwin"* ]]; then
    DEFAULT_PATH="$HOME/Documents/ZettaBrain"
  elif [[ -d "/mnt" ]]; then
    DEFAULT_PATH="/mnt/Rag-data"
  else
    DEFAULT_PATH="/var/zettabrain/data"
  fi

  echo -e "  Enter the full path to your documents folder."
  echo -e "  ${CYAN}Examples:${NC}"
  echo -e "    Linux : /home/user/documents"
  echo -e "    macOS : /Users/username/Documents/ZettaBrain"
  echo -e "    Win   : /mnt/c/Users/username/Documents  (WSL)"
  echo ""

  while true; do
    read -rp "  Documents path [${DEFAULT_PATH}]: " LOCAL_PATH
    LOCAL_PATH="${LOCAL_PATH:-$DEFAULT_PATH}"

    if [ -d "$LOCAL_PATH" ]; then
      FILE_COUNT=$(find "$LOCAL_PATH" -maxdepth 3 -type f 2>/dev/null | wc -l)
      success "Path exists. Files found: ${FILE_COUNT}"
      break
    else
      ask "Path does not exist. Create it? [Y/n]: "
      read -r CREATE_PATH
      if [[ ! $CREATE_PATH =~ ^[Nn]$ ]]; then
        mkdir -p "$LOCAL_PATH"
        success "Created: ${LOCAL_PATH}"
        FILE_COUNT=0
        break
      fi
    fi
  done

  MOUNT_POINT="$LOCAL_PATH"
  STORAGE_LABEL="local:${LOCAL_PATH}"
  info "Using local path: ${MOUNT_POINT}"

fi

# ── NFS ────────────────────────────────────────────────
if [ "$STORAGE_TYPE" = "nfs" ]; then

  step "NFS Share Configuration ─────────────────────────"
  echo ""

  # Install NFS client
  info "Installing NFS client..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq nfs-common netcat-openbsd
  elif command -v yum &>/dev/null; then
    yum install -y -q nfs-utils nmap-ncat
  elif command -v dnf &>/dev/null; then
    dnf install -y -q nfs-utils nmap-ncat
  fi
  success "NFS client ready."
  echo ""

  # NFS Server IP
  while true; do
    read -rp "  NFS Server IP address: " NFS_SERVER_IP
    if [[ $NFS_SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      break
    else
      warn "Invalid IP. Example: 192.168.1.100"
    fi
  done

  # NFS Export Path
  while true; do
    read -rp "  NFS export path (e.g. /exports/documents): " NFS_EXPORT_PATH
    if [[ $NFS_EXPORT_PATH == /* ]]; then
      break
    else
      warn "Path must start with /. Example: /exports/documents"
    fi
  done

  # Mount point
  echo ""
  echo -e "  Local mount point [${MOUNT_POINT}]: "
  read -rp "  Press Enter to accept or type a custom path: " CUSTOM_MOUNT
  [ -n "$CUSTOM_MOUNT" ] && MOUNT_POINT="$CUSTOM_MOUNT"

  # Test connectivity
  echo ""
  info "Testing NFS port 2049 on ${NFS_SERVER_IP}..."
  if command -v nc &>/dev/null; then
    if nc -zw5 "$NFS_SERVER_IP" 2049 &>/dev/null; then
      success "NFS port 2049 is open."
    else
      error "Cannot reach port 2049 on ${NFS_SERVER_IP}."
      error "Check: security group rules, NFS server firewall."
      exit 1
    fi
  else
    warn "netcat not found — skipping port check."
  fi

  # Create mount point
  mkdir -p "$MOUNT_POINT"

  # Unmount if already mounted
  mountpoint -q "$MOUNT_POINT" && umount "$MOUNT_POINT" && warn "Previous mount removed."

  # Mount
  info "Mounting ${NFS_SERVER_IP}:${NFS_EXPORT_PATH} → ${MOUNT_POINT}..."
  if mount -t nfs -o "$NFS_OPTS" "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$MOUNT_POINT"; then
    FILE_COUNT=$(find "$MOUNT_POINT" -maxdepth 2 -type f 2>/dev/null | wc -l)
    success "Mounted. Files visible: ${FILE_COUNT}"
  else
    error "Mount failed. Verify the export path and client IP permissions."
    exit 1
  fi

  # Persist in fstab
  FSTAB_ENTRY="${NFS_SERVER_IP}:${NFS_EXPORT_PATH}  ${MOUNT_POINT}  nfs  ${NFS_OPTS}  0  0"
  if grep -qF "${NFS_SERVER_IP}:${NFS_EXPORT_PATH}" "$FSTAB_FILE"; then
    warn "fstab entry already exists — skipping."
  else
    cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    { echo ""; echo "# ZettaBrain NFS — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$FSTAB_ENTRY"; } >> "$FSTAB_FILE"
    success "Added to /etc/fstab — persists after reboot."
  fi
  systemctl daemon-reload 2>/dev/null || true

  STORAGE_LABEL="nfs:${NFS_SERVER_IP}:${NFS_EXPORT_PATH}"

fi

# ── SMB / CIFS ─────────────────────────────────────────
if [ "$STORAGE_TYPE" = "smb" ]; then

  step "SMB / CIFS Share Configuration ────────────────────"
  echo ""

  # Install cifs-utils
  info "Installing SMB client (cifs-utils)..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq cifs-utils netcat-openbsd
  elif command -v yum &>/dev/null; then
    yum install -y -q cifs-utils nmap-ncat
  elif command -v dnf &>/dev/null; then
    dnf install -y -q cifs-utils nmap-ncat
  fi
  success "SMB client ready."
  echo ""

  # SMB Server IP
  while true; do
    read -rp "  SMB Server IP address: " SMB_SERVER_IP
    if [[ $SMB_SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      break
    else
      warn "Invalid IP. Example: 192.168.1.50"
    fi
  done

  # SMB Share name
  while true; do
    read -rp "  SMB share name (e.g. documents or shared): " SMB_SHARE
    if [ -n "$SMB_SHARE" ]; then
      break
    else
      warn "Share name cannot be empty."
    fi
  done

  # Credentials
  echo ""
  echo -e "  ${CYAN}Authentication${NC}"
  read -rp "  Username (leave blank for guest): " SMB_USER
  if [ -n "$SMB_USER" ]; then
    read -rsp "  Password: " SMB_PASS
    echo ""
  fi

  # Domain (optional)
  read -rp "  Domain (leave blank if not required): " SMB_DOMAIN

  # Mount point
  echo ""
  echo -e "  Local mount point [${MOUNT_POINT}]: "
  read -rp "  Press Enter to accept or type a custom path: " CUSTOM_MOUNT
  [ -n "$CUSTOM_MOUNT" ] && MOUNT_POINT="$CUSTOM_MOUNT"

  # Test connectivity (SMB port 445)
  echo ""
  info "Testing SMB port 445 on ${SMB_SERVER_IP}..."
  if command -v nc &>/dev/null; then
    if nc -zw5 "$SMB_SERVER_IP" 445 &>/dev/null; then
      success "SMB port 445 is open."
    else
      error "Cannot reach port 445 on ${SMB_SERVER_IP}."
      error "Check: firewall rules, security groups, SMB server is running."
      exit 1
    fi
  else
    warn "netcat not found — skipping port check."
  fi

  # Build credentials file (more secure than passing in mount options)
  CREDS_FILE="/etc/zettabrain-smb.credentials"
  {
    echo "username=${SMB_USER:-guest}"
    [ -n "$SMB_PASS" ]   && echo "password=${SMB_PASS}"
    [ -n "$SMB_DOMAIN" ] && echo "domain=${SMB_DOMAIN}"
  } > "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  success "Credentials saved: ${CREDS_FILE}"

  # Build mount options
  SMB_MOUNT_OPTS="${SMB_OPTS},credentials=${CREDS_FILE}"

  # Create mount point
  mkdir -p "$MOUNT_POINT"

  # Unmount if already mounted
  mountpoint -q "$MOUNT_POINT" && umount "$MOUNT_POINT" && warn "Previous mount removed."

  # Mount
  info "Mounting //${SMB_SERVER_IP}/${SMB_SHARE} → ${MOUNT_POINT}..."
  if mount -t cifs "//${SMB_SERVER_IP}/${SMB_SHARE}" "$MOUNT_POINT" \
     -o "$SMB_MOUNT_OPTS" 2>/dev/null; then
    FILE_COUNT=$(find "$MOUNT_POINT" -maxdepth 2 -type f 2>/dev/null | wc -l)
    success "Mounted. Files visible: ${FILE_COUNT}"
  else
    error "SMB mount failed."
    error "Common causes:"
    error "  - Wrong share name (check: smbclient -L //${SMB_SERVER_IP})"
    error "  - Wrong credentials"
    error "  - SMB version mismatch (try adding vers=2.0 or vers=3.0)"
    exit 1
  fi

  # Persist in fstab
  FSTAB_ENTRY="//${SMB_SERVER_IP}/${SMB_SHARE}  ${MOUNT_POINT}  cifs  ${SMB_MOUNT_OPTS},_netdev  0  0"
  if grep -qF "//${SMB_SERVER_IP}/${SMB_SHARE}" "$FSTAB_FILE"; then
    warn "fstab entry already exists — skipping."
  else
    cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    { echo ""; echo "# ZettaBrain SMB — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$FSTAB_ENTRY"; } >> "$FSTAB_FILE"
    success "Added to /etc/fstab — persists after reboot."
  fi
  systemctl daemon-reload 2>/dev/null || true

  STORAGE_LABEL="smb://${SMB_SERVER_IP}/${SMB_SHARE}"

fi

# -------------------------------------------------------
# STEP 2/5 — INSTALL OLLAMA
# -------------------------------------------------------
step "Step 2/5: Installing Ollama ────────────────────────"

if command -v ollama &>/dev/null; then
  info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown')"
else
  info "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh >> "$LOG_FILE" 2>&1
  success "Ollama installed."
fi

if systemctl is-active --quiet ollama 2>/dev/null; then
  info "Ollama service already running."
else
  info "Starting Ollama service..."
  systemctl enable ollama >> "$LOG_FILE" 2>&1 || true
  systemctl start  ollama >> "$LOG_FILE" 2>&1 || true
  sleep 5
fi

# Wait for Ollama to be ready
RETRIES=0
until curl -s "$OLLAMA_URL" &>/dev/null || [ $RETRIES -ge 12 ]; do
  info "Waiting for Ollama... (${RETRIES}/12)"
  sleep 3
  RETRIES=$((RETRIES + 1))
done

if curl -s "$OLLAMA_URL" &>/dev/null; then
  success "Ollama is running at ${OLLAMA_URL}"
else
  error "Ollama did not start. Try: systemctl start ollama"
  exit 1
fi

# -------------------------------------------------------
# STEP 3/5 — PULL REQUIRED MODELS
# -------------------------------------------------------
step "Step 3/5: Pulling AI models ────────────────────────"

# Embedding model — required (~275MB)
if ollama list 2>/dev/null | grep -q "$EMBED_MODEL"; then
  info "Embedding model already present: ${EMBED_MODEL}"
else
  info "Pulling embedding model: ${EMBED_MODEL} (~275MB)..."
  ollama pull "$EMBED_MODEL"
  success "Embedding model ready."
fi

# LLM — optional (large download)
LLM_MODEL="${ZETTABRAIN_LLM_MODEL:-llama3.1:8b}"
if ollama list 2>/dev/null | grep -q "$LLM_MODEL"; then
  info "LLM already present: ${LLM_MODEL}"
else
  warn "LLM model not found: ${LLM_MODEL}"
  echo ""
  read -rp "  Pull LLM model now (~4.9GB)? [y/N]: " PULL_LLM
  if [[ $PULL_LLM =~ ^[Yy]$ ]]; then
    info "Pulling ${LLM_MODEL}..."
    ollama pull "$LLM_MODEL"
    success "LLM ready: ${LLM_MODEL}"
  else
    warn "Skipped. Run later: ollama pull ${LLM_MODEL}"
  fi
fi

# -------------------------------------------------------
# STEP 4/5 — GENERATE TLS CERTIFICATE
# -------------------------------------------------------
step "Step 4/5: Generating TLS certificate ──────────────"

# Install openssl if not present
if ! command -v openssl &>/dev/null; then
  info "Installing openssl..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y -qq openssl
  elif command -v yum &>/dev/null; then
    yum install -y -q openssl
  elif command -v dnf &>/dev/null; then
    dnf install -y -q openssl
  fi
fi

mkdir -p "$CERT_DIR"
CERT_FILE="${CERT_DIR}/cert.pem"
KEY_FILE="${CERT_DIR}/key.pem"
CERT_CONF="${CERT_DIR}/openssl.cnf"

# Detect server IP addresses and hostname
SERVER_HOST=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")
SERVER_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' || echo "127.0.0.1")

# Always include localhost and 127.0.0.1
PRIMARY_IP=$(echo "$SERVER_IPS" | head -1)
info "Generating certificate for:"
info "  Hostname : ${SERVER_HOST}"
info "  IPs      : $(echo $SERVER_IPS | tr '\n' ' ')"

# Build SAN list
SAN_LIST="DNS:localhost,DNS:${SERVER_HOST},IP:127.0.0.1"
while IFS= read -r ip; do
  [ -n "$ip" ] && SAN_LIST="${SAN_LIST},IP:${ip}"
done <<< "$SERVER_IPS"

# Allow user to add extra IPs or domains
echo ""
read -rp "  Add extra IP or domain to certificate? (e.g. 10.0.1.50 or myserver.example.com) [blank to skip]: " EXTRA_SAN
if [ -n "$EXTRA_SAN" ]; then
  if [[ $EXTRA_SAN =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN_LIST="${SAN_LIST},IP:${EXTRA_SAN}"
  else
    SAN_LIST="${SAN_LIST},DNS:${EXTRA_SAN}"
  fi
  info "Added to certificate: ${EXTRA_SAN}"
fi

# Write openssl config
cat > "$CERT_CONF" << SSLCONF
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
subjectAltName     = ${SAN_LIST}
keyUsage           = critical, digitalSignature, keyEncipherment
extendedKeyUsage   = serverAuth
basicConstraints   = critical, CA:false
SSLCONF

# Generate private key and certificate
openssl req -x509 -nodes \
  -newkey rsa:2048 \
  -keyout "$KEY_FILE" \
  -out    "$CERT_FILE" \
  -days   3650 \
  -config "$CERT_CONF" \
  >> "$LOG_FILE" 2>&1

chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# Show certificate fingerprint
FINGERPRINT=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null \
              | sed 's/SHA256 Fingerprint=//')

success "TLS certificate generated (valid 10 years)."
info "Certificate : ${CERT_FILE}"
info "Private key : ${KEY_FILE}"
info "SANs        : ${SAN_LIST}"
info "Fingerprint : ${FINGERPRINT}"

# -------------------------------------------------------
# SAVE CONFIGURATION
# -------------------------------------------------------
mkdir -p "$DEPLOY_DIR"
cat > "$CONFIG_FILE" << ENVEOF
# ZettaBrain Configuration — $(date '+%Y-%m-%d %H:%M:%S')

# Storage
STORAGE_TYPE="${STORAGE_TYPE}"
STORAGE_LABEL="${STORAGE_LABEL}"
RAG_DATA_PATH="${MOUNT_POINT}"
ZETTABRAIN_DOCS="${MOUNT_POINT}"

# Ollama
OLLAMA_HOST="${OLLAMA_URL}"
ZETTABRAIN_LLM_MODEL="${LLM_MODEL}"
ZETTABRAIN_EMBED_MODEL="${EMBED_MODEL}"

# TLS
ZETTABRAIN_CERT="${CERT_FILE}"
ZETTABRAIN_KEY="${KEY_FILE}"
ZETTABRAIN_TLS_FINGERPRINT="${FINGERPRINT}"
ZETTABRAIN_SERVER_HOST="${PRIMARY_IP}"
ENVEOF

success "Config saved: ${CONFIG_FILE}"

# -------------------------------------------------------
# STEP 5/5 — BUILD RAG VECTOR STORE
# -------------------------------------------------------
step "Step 5/5: Building RAG vector store ──────────────"

# Python detection — find the one with langchain installed
PYTHON_BIN=""

# Method 1: Read venv path from pipx shim
SHIM=$(find /root/.local/bin /home/*/.local/bin \
       -name "zettabrain-chat" -type f 2>/dev/null | head -1)

if [ -n "$SHIM" ] && [ -f "$SHIM" ]; then
  VENV_ROOT=$(find /root/.local/share/pipx/venvs \
              /home/*/.local/share/pipx/venvs \
              -maxdepth 1 -name "zettabrain-rag" -type d 2>/dev/null | head -1)
  for py in \
      "${VENV_ROOT}/bin/python3" \
      "${VENV_ROOT}/bin/python" \
      "${VENV_ROOT}/bin/python3.14" \
      "${VENV_ROOT}/bin/python3.12" \
      "${VENV_ROOT}/bin/python3.11"; do
    if [ -f "$py" ] && "$py" -c "import langchain_community" 2>/dev/null; then
      PYTHON_BIN="$py"
      info "Python (pipx shim): ${PYTHON_BIN}"
      break
    fi
  done
fi

# Method 2: Search venv directories directly
if [ -z "$PYTHON_BIN" ]; then
  for venv_root in \
      /root/.local/share/pipx/venvs/zettabrain-rag \
      /home/*/.local/share/pipx/venvs/zettabrain-rag \
      /opt/zettabrain/venv; do
    for py in \
        "${venv_root}/bin/python3" \
        "${venv_root}/bin/python" \
        "${venv_root}/bin/python3.14" \
        "${venv_root}/bin/python3.12" \
        "${venv_root}/bin/python3.11"; do
      if [ -f "$py" ] && "$py" -c "import langchain_community" 2>/dev/null; then
        PYTHON_BIN="$py"
        info "Python (venv search): ${PYTHON_BIN}"
        break 2
      fi
    done
  done
fi

# Method 3: System python
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

# Build vector store or warn
DOC_COUNT=0
if [ -z "$PYTHON_BIN" ]; then
  warn "Could not find Python with langchain installed."
  warn "Build the vector store manually:"
  warn "  find /root/.local/share/pipx/venvs/zettabrain-rag -name 'python*' | head -3"
  warn "  <python_path> ${RAG_SCRIPT} --rebuild"
elif [ ! -f "$RAG_SCRIPT" ]; then
  error "RAG script not found: ${RAG_SCRIPT}"
  error "Run: zettabrain-chat --rebuild"
else
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

    if ZETTABRAIN_DOCS="$MOUNT_POINT" "$PYTHON_BIN" "$RAG_SCRIPT" --rebuild; then
      echo ""
      success "Vector store built successfully."
      log "RAG rebuild complete. Docs: ${DOC_COUNT}"
    else
      echo ""
      error "RAG rebuild failed. Run manually:"
      error "  cd ${DEPLOY_DIR} && ${PYTHON_BIN} 03_langchain_rag.py --rebuild"
    fi
  fi
fi

# -------------------------------------------------------
# DONE
# -------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         ZettaBrain Setup Complete!  🎉               ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Storage     : ${GREEN}${STORAGE_LABEL}${NC}"
echo -e "  Mount       : ${GREEN}${MOUNT_POINT}${NC}"
echo -e "  Documents   : ${GREEN}${DOC_COUNT} file(s)${NC}"
echo -e "  TLS cert    : ${GREEN}${CERT_FILE}${NC}"
echo -e "  Config      : ${GREEN}${CONFIG_FILE}${NC}"
echo ""
echo -e "${CYAN}─── Start the Secure GUI ────────────────────────────────${NC}"
echo ""
echo -e "  ${GREEN}zettabrain-server --port 443${NC}"
echo ""
echo -e "  Then open in your browser:"
echo -e "  ${BOLD}https://${PRIMARY_IP}:443${NC}"
echo ""
echo -e "${YELLOW}  Note: Your browser will show a certificate warning on first visit."
echo -e "  This is expected for a self-signed certificate."
echo -e "  Click 'Advanced' → 'Proceed' to accept.${NC}"
echo ""
echo -e "  Certificate fingerprint (SHA-256):"
echo -e "  ${CYAN}${FINGERPRINT}${NC}"
echo ""
echo -e "${CYAN}─── Other Commands ──────────────────────────────────────${NC}"
echo ""
echo -e "  CLI chat   : ${YELLOW}zettabrain-chat${NC}"
echo -e "  Rebuild    : ${YELLOW}zettabrain-chat --rebuild${NC}"
echo -e "  Status     : ${YELLOW}zettabrain-status${NC}"
echo ""

log "Setup complete. Storage: ${STORAGE_LABEL} | Docs: ${DOC_COUNT} | Cert: ${CERT_FILE}"
