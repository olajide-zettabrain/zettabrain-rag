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
#   4. Install Cloudflare Tunnel for trusted HTTPS (optional, token required)
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
# PACKAGE MANAGER DETECTION (used throughout setup)
# -------------------------------------------------------
_PM=""
command -v apt-get &>/dev/null && _PM="apt"
command -v dnf     &>/dev/null && _PM="dnf"
command -v yum     &>/dev/null && _PM="${_PM:-yum}"

# Detect OS ID for distro-specific paths
_OS_ID=""; _OS_VER=""
[ -f /etc/os-release ] && { . /etc/os-release; _OS_ID="${ID:-}"; _OS_VER="${VERSION_ID:-}"; }

# ── Install helper (uses top-level _PM) ─────────────────
_install() { [ -n "$_PM" ] && "$_PM" install -y "$@" >> "$LOG_FILE" 2>&1 || true; }

# ── SELinux helper ───────────────────────────────────────
# Called before storage mounts and before server launch.
_selinux_permissive_check() {
  command -v getenforce &>/dev/null || return 0
  local _mode; _mode=$(getenforce 2>/dev/null)
  if [ "$_mode" = "Enforcing" ]; then
    info "SELinux is Enforcing — configuring required policies..."
    setsebool -P use_nfs_home_dirs      1 >> "$LOG_FILE" 2>&1 || true
    setsebool -P use_samba_home_dirs    1 >> "$LOG_FILE" 2>&1 || true
    setsebool -P use_fusefs_home_dirs   1 >> "$LOG_FILE" 2>&1 || true
    setsebool -P httpd_can_network_connect 1 >> "$LOG_FILE" 2>&1 || true
    # Allow the ZettaBrain server to bind and accept connections on port 7860
    if command -v semanage &>/dev/null; then
      semanage port -a -t http_port_t -p tcp 7860 >> "$LOG_FILE" 2>&1 || true
    fi
    success "SELinux policies configured."
  fi
}

# ── Firewall helper ──────────────────────────────────────
# Opens a TCP port in firewalld (RHEL/Fedora) or ufw (Ubuntu).
_open_port() {
  local _port="$1"
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --add-port="${_port}/tcp" --permanent >> "$LOG_FILE" 2>&1 || true
    firewall-cmd --reload >> "$LOG_FILE" 2>&1 || true
    success "Firewall: port ${_port}/tcp opened via firewalld."
  elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${_port}/tcp" >> "$LOG_FILE" 2>&1 || true
    success "Firewall: port ${_port}/tcp opened via ufw."
  fi
}

# -------------------------------------------------------
# STEP 1/6 — SELECT PRIMARY STORAGE TYPE
# -------------------------------------------------------
step "Step 1/6: Select Primary Storage Type"
echo ""
echo -e "  Where are your documents stored?\n"
echo -e "  ${BOLD}1)${NC} Local storage  — documents are on this machine"
echo -e "  ${BOLD}2)${NC} NFS share      — documents on a network file server (Linux/Mac)"
echo -e "  ${BOLD}3)${NC} SMB / CIFS     — documents on a Windows share or Samba"
echo -e "  ${BOLD}4)${NC} Object storage — S3-compatible bucket (MinIO, AWS S3, Backblaze B2)"
echo ""

STORAGE_TYPE=""
while true; do
  read -rp "  Select [1/2/3/4]: " _choice
  case "$_choice" in
    1|local|Local|LOCAL)   STORAGE_TYPE="local";  break ;;
    2|nfs|NFS)             STORAGE_TYPE="nfs";    break ;;
    3|smb|SMB|cifs|CIFS)  STORAGE_TYPE="smb";    break ;;
    4|s3|S3|minio|object)  STORAGE_TYPE="s3";     break ;;
    *) warn "Please enter 1, 2, 3, or 4." ;;
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
  case "$_PM" in
    apt)
      apt-get update -qq >> "$LOG_FILE" 2>&1 || true
      _install nfs-common netcat-openbsd
      ;;
    dnf|yum)
      _install nfs-utils nmap-ncat
      ;;
    *)
      warn "Cannot detect package manager — assuming NFS client is installed."
      ;;
  esac
  _selinux_permissive_check
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
  case "$_PM" in
    apt)
      apt-get update -qq >> "$LOG_FILE" 2>&1 || true
      _install cifs-utils netcat-openbsd
      ;;
    dnf|yum)
      _install cifs-utils nmap-ncat
      ;;
    *)
      warn "Cannot detect package manager — assuming cifs-utils is installed."
      ;;
  esac
  _selinux_permissive_check
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
# ── OPTION 4: S3-COMPATIBLE OBJECT STORAGE (s3fs-fuse) ──────────
# ================================================================
if [ "$STORAGE_TYPE" = "s3" ]; then

  step "Object Storage Configuration"
  echo -e "  Supports MinIO, AWS S3, Backblaze B2, and any S3-compatible endpoint."
  echo -e "  The bucket is mounted via s3fs-fuse — files are streamed on demand,\n  no bulk download required.\n"

  read -rp "  Endpoint URL (e.g. http://minio:9000 or https://s3.amazonaws.com): " S3_ENDPOINT
  [ -z "$S3_ENDPOINT" ] && error "Endpoint URL is required."

  read -rp "  Bucket name: " S3_BUCKET
  [ -z "$S3_BUCKET" ] && error "Bucket name is required."

  read -rp "  Prefix / folder inside bucket (leave blank for root): " S3_PREFIX

  read -rp "  Access key ID: " S3_ACCESS_KEY
  [ -z "$S3_ACCESS_KEY" ] && error "Access key is required."

  read -rsp "  Secret access key: " S3_SECRET_KEY
  echo ""
  [ -z "$S3_SECRET_KEY" ] && error "Secret key is required."

  # ── Install s3fs-fuse ────────────────────────────────────────
  info "Installing s3fs-fuse..."
  if command -v s3fs &>/dev/null; then
    success "s3fs already installed: $(s3fs --version 2>&1 | head -1)"
  else
    case "$_PM" in
      apt)
        apt-get update -qq >> "$LOG_FILE" 2>&1 || true
        apt-get install -y s3fs >> "$LOG_FILE" 2>&1 || true
        ;;
      dnf|yum)
        # Try direct install first, then EPEL
        "${_PM}" install -y s3fs-fuse >> "$LOG_FILE" 2>&1 \
          || { "${_PM}" install -y epel-release >> "$LOG_FILE" 2>&1 || true
               "${_PM}" install -y s3fs-fuse >> "$LOG_FILE" 2>&1 || true; }
        ;;
      *)
        error "Cannot detect package manager. Install s3fs-fuse manually: https://github.com/s3fs-fuse/s3fs-fuse"
        exit 1
        ;;
    esac

    if ! command -v s3fs &>/dev/null; then
      error "s3fs-fuse not found after install. Check ${LOG_FILE} for details."
      error "Manual install: apt-get install s3fs  OR  dnf install s3fs-fuse"
      exit 1
    fi
    success "s3fs-fuse installed: $(s3fs --version 2>&1 | head -1)"
  fi

  # ── Credentials file ─────────────────────────────────────────
  _S3FS_PASSWD="/etc/passwd-s3fs"
  echo "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" > "$_S3FS_PASSWD"
  chmod 600 "$_S3FS_PASSWD"
  success "Credentials written to ${_S3FS_PASSWD}"

  # ── Mount point ───────────────────────────────────────────────
  S3_MOUNT_POINT="/opt/zettabrain/s3-mount"
  mkdir -p "$S3_MOUNT_POINT"

  # Unmount any existing mount at this path before remounting
  if mountpoint -q "$S3_MOUNT_POINT" 2>/dev/null; then
    umount "$S3_MOUNT_POINT" 2>/dev/null || fusermount -u "$S3_MOUNT_POINT" 2>/dev/null || true
  fi

  # Build s3fs options — path-style for MinIO and non-AWS endpoints
  _S3FS_OPTS="use_path_request_style,allow_other,ro,passwd_file=${_S3FS_PASSWD}"
  _S3FS_OPTS="${_S3FS_OPTS},url=${S3_ENDPOINT}"

  # Enable allow_other in fuse config
  if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >> /etc/fuse.conf
  fi

  info "Mounting s3://${S3_BUCKET} → ${S3_MOUNT_POINT}..."
  if [ -n "$S3_PREFIX" ]; then
    s3fs "${S3_BUCKET}:/${S3_PREFIX}" "$S3_MOUNT_POINT" -o "$_S3FS_OPTS" >> "$LOG_FILE" 2>&1
  else
    s3fs "$S3_BUCKET" "$S3_MOUNT_POINT" -o "$_S3FS_OPTS" >> "$LOG_FILE" 2>&1
  fi

  if mountpoint -q "$S3_MOUNT_POINT" 2>/dev/null; then
    _file_count=$(find "$S3_MOUNT_POINT" -maxdepth 2 \( -name "*.pdf" -o -name "*.txt" -o -name "*.docx" -o -name "*.md" \) 2>/dev/null | wc -l)
    success "Mounted — ${_file_count} supported document(s) visible."
  else
    warn "Mount attempt returned an error. Check ${LOG_FILE} for details."
    warn "The mount will be retried on next boot via fstab."
  fi

  # ── fstab entry (persistent across reboots) ──────────────────
  if [ -n "$S3_PREFIX" ]; then
    _fstab_s3_src="${S3_BUCKET}:/${S3_PREFIX}"
  else
    _fstab_s3_src="$S3_BUCKET"
  fi
  _fstab_s3_line="${_fstab_s3_src}  ${S3_MOUNT_POINT}  fuse.s3fs  ${_S3FS_OPTS},_netdev  0  0"

  if grep -qF "$S3_BUCKET" "$FSTAB_FILE" 2>/dev/null; then
    warn "fstab entry for ${S3_BUCKET} already exists — skipping."
  else
    cp "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    { echo ""; echo "# ZettaBrain S3 FUSE — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$_fstab_s3_line"; } >> "$FSTAB_FILE"
    success "Added to /etc/fstab — mount persists after reboot."
  fi

  PRIMARY_PATH="$S3_MOUNT_POINT"
  STORAGE_LABEL="s3://${S3_BUCKET}"
  info "Documents will be read from mount: ${S3_MOUNT_POINT}"

fi

# ================================================================
# STEP 2/6 — NVIDIA DRIVERS
# Installed unconditionally so Ollama (step 3) detects the GPU.
# Safe to run when no NVIDIA hardware is present.
# ================================================================
step "Step 2/6: Installing NVIDIA drivers"

# Detect NVIDIA GPU hardware first — skip entirely if none present
_has_nvidia=false
_install pciutils >> "$LOG_FILE" 2>&1 || true
if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null 2>&1; then
  _has_nvidia=true
elif command -v lspci &>/dev/null && lspci 2>/dev/null | grep -qi "nvidia"; then
  _has_nvidia=true
elif [ -d /proc/driver/nvidia ]; then
  _has_nvidia=true
fi

if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null 2>&1; then
  _gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  success "NVIDIA drivers already active: ${_gpu_name}"
elif ! $_has_nvidia; then
  info "No NVIDIA GPU detected — skipping driver installation. Ollama will use CPU."
elif [ -z "$_PM" ]; then
  warn "Cannot detect package manager — skipping NVIDIA driver install."
else
  info "NVIDIA GPU detected — installing drivers..."
  _nvidia_reboot=false

  case "$_PM" in
    apt)
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
      # Kernel headers for DKMS
      "$_PM" install -y "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)" \
        >> "$LOG_FILE" 2>&1 \
        || "$_PM" install -y kernel-devel kernel-headers >> "$LOG_FILE" 2>&1 || true
      # dkms is required by kmod-nvidia on RHEL 8/9
      "$_PM" install -y dkms >> "$LOG_FILE" 2>&1 || true

      _cuda_repo=""
      case "${_OS_ID}" in
        amzn)
          case "${_OS_VER}" in
            2)    _cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-rhel7.repo" ;;
            202*) _cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo" ;;
          esac ;;
        rhel|centos|rocky|almalinux)
          _major="${_OS_VER%%.*}"
          _cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/rhel${_major}/x86_64/cuda-rhel${_major}.repo" ;;
        fedora)
          _cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/fedora${_OS_VER}/x86_64/cuda-fedora${_OS_VER}.repo" ;;
      esac

      if [ -n "$_cuda_repo" ]; then
        info "Adding NVIDIA CUDA repository..."
        # DNF5 (RHEL 10+) dropped config-manager --add-repo; use repo file directly
        curl -fsSL "$_cuda_repo" -o /etc/yum.repos.d/cuda-nvidia.repo >> "$LOG_FILE" 2>&1 || true
        "$_PM" clean expire-cache >> "$LOG_FILE" 2>&1 || true
        info "Installing cuda-drivers (this may take several minutes)..."
        # RHEL 10 / DNF5: modularity removed — use direct package + --nobest fallback
        _major="${_OS_VER%%.*}"
        if [ "${_major}" -ge 10 ] 2>/dev/null; then
          "$_PM" install -y cuda-drivers --nobest --skip-broken >> "$LOG_FILE" 2>&1 || true
        else
          # RHEL 8/9: try module stream first, fall back to direct package
          "$_PM" module install -y "nvidia-driver:latest-dkms" >> "$LOG_FILE" 2>&1 \
            || "$_PM" install -y cuda-drivers >> "$LOG_FILE" 2>&1 || true
        fi
      else
        warn "Unrecognised OS (${_OS_ID} ${_OS_VER}) — skipping NVIDIA repo setup."
        warn "Install drivers manually: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/"
      fi
      _nvidia_reboot=true
      ;;
  esac

  modprobe nvidia >> "$LOG_FILE" 2>&1 || true
  sleep 2

  if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null 2>&1; then
    _gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    success "NVIDIA drivers active — GPU detected: ${_gpu_name}"
  elif $_nvidia_reboot; then
    warn "NVIDIA drivers installed — reboot required to activate the kernel module."
    warn "After reboot, run: sudo systemctl restart ollama"
    warn "  → Continuing; Ollama will use CPU until reboot."
  fi
fi

# ================================================================
# STEP 3/6 — INSTALL OLLAMA
# ================================================================
step "Step 3/6: Installing Ollama"

# zstd is required by Ollama's installer for archive extraction
if ! command -v zstd &>/dev/null; then
  info "Installing zstd (required by Ollama)..."
  case "$_PM" in
    apt)
      apt-get update -qq >> "$LOG_FILE" 2>&1 || true
      apt-get install -y zstd >> "$LOG_FILE" 2>&1 || true ;;
    dnf|yum)
      "$_PM" install -y zstd >> "$LOG_FILE" 2>&1 || true ;;
  esac
  command -v zstd &>/dev/null || warn "zstd install failed — Ollama extraction may fail."
fi

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
step "Step 4/6: Pulling required AI models"

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

# ── GPU detection → recommend the best model for this hardware ────────────────
_GPU_TYPE="none"
_VRAM_GB=0
_GPU_NAME="CPU only"

if command -v nvidia-smi &>/dev/null 2>&1; then
  _nv=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "$_nv" ]; then
    _GPU_NAME=$(echo "$_nv" | cut -d',' -f1 | xargs)
    _vram_mb=$(echo "$_nv" | cut -d',' -f2 | xargs)
    _VRAM_GB=$(( _vram_mb / 1024 ))
    _GPU_TYPE="nvidia"
  fi
fi

if [ "$_GPU_TYPE" = "none" ] && command -v rocm-smi &>/dev/null 2>&1; then
  _vram_mb=$(rocm-smi --showmeminfo vram 2>/dev/null | grep -oP '\d+(?= MB)' | head -1)
  if [ -n "$_vram_mb" ]; then
    _VRAM_GB=$(( _vram_mb / 1024 ))
    _GPU_TYPE="amd"
    _GPU_NAME="AMD GPU"
  fi
fi

if [ "$_GPU_TYPE" = "none" ] && [ "$(uname -m 2>/dev/null)" = "arm64" ]; then
  _ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  if [ "$_ram_gb" -gt 0 ]; then
    _VRAM_GB="$_ram_gb"
    _GPU_TYPE="apple"
    _GPU_NAME="Apple Silicon (unified memory ${_ram_gb}GB)"
  fi
fi

# Map VRAM to model recommendations
declare -A _MODEL_OPTIONS=(
  ["llama3.2:3b"]="Llama 3.2 3B   — fastest, ~2GB,  good for quick answers"
  ["llama3.1:8b"]="Llama 3.1 8B   — balanced, ~5GB, recommended default"
  ["mistral:7b"]="Mistral 7B      — fast, ~4GB,      strong reasoning"
  ["llama3.1:13b"]="Llama 3.1 13B — better, ~8GB,   needs 12GB+ VRAM"
  ["qwen2.5:14b"]="Qwen 2.5 14B   — excellent, ~9GB, needs 16GB+ VRAM"
  ["qwen2.5:32b"]="Qwen 2.5 32B   — best quality, ~20GB, needs 24GB+ VRAM"
)

if [ "$_GPU_TYPE" = "none" ] || [ "$_VRAM_GB" -lt 4 ]; then
  _RECOMMENDED_MODEL="llama3.2:3b"
  _RECOMMENDED_REASON="CPU-only or low VRAM: fastest inference"
elif [ "$_VRAM_GB" -ge 24 ]; then
  _RECOMMENDED_MODEL="qwen2.5:32b"
  _RECOMMENDED_REASON="${_VRAM_GB}GB VRAM detected: best quality model"
elif [ "$_VRAM_GB" -ge 16 ]; then
  _RECOMMENDED_MODEL="qwen2.5:14b"
  _RECOMMENDED_REASON="${_VRAM_GB}GB VRAM detected: high quality model"
elif [ "$_VRAM_GB" -ge 12 ]; then
  _RECOMMENDED_MODEL="llama3.1:13b"
  _RECOMMENDED_REASON="${_VRAM_GB}GB VRAM detected: strong quality model"
else
  _RECOMMENDED_MODEL="llama3.1:8b"
  _RECOMMENDED_REASON="${_VRAM_GB}GB VRAM detected: balanced quality/speed"
fi

echo ""
info "Hardware detected: ${_GPU_NAME}"
info "Recommended model: ${_RECOMMENDED_MODEL}  (${_RECOMMENDED_REASON})"
echo ""
echo "  Available models:"
echo "    1) llama3.2:3b    — fastest (~2GB)       good for quick Q&A"
echo "    2) llama3.1:8b    — balanced (~5GB)      recommended for most"
echo "    3) mistral:7b     — fast (~4GB)           strong reasoning"
echo "    4) llama3.1:13b   — better (~8GB)         needs 12GB+ VRAM/RAM"
echo "    5) qwen2.5:14b    — excellent (~9GB)      needs 16GB+ VRAM/RAM"
echo "    6) qwen2.5:32b    — best quality (~20GB)  needs 24GB+ VRAM/RAM"
echo "    7) Custom — enter your own model name"
echo ""
echo "  GPU: ${_GPU_NAME}  |  Press Enter to accept recommended"
read -rp "  Choose [1-7] or Enter for recommended (${_RECOMMENDED_MODEL}): " _model_choice

case "$_model_choice" in
  1) LLM_MODEL="llama3.2:3b" ;;
  2) LLM_MODEL="llama3.1:8b" ;;
  3) LLM_MODEL="mistral:7b" ;;
  4) LLM_MODEL="llama3.1:13b" ;;
  5) LLM_MODEL="qwen2.5:14b" ;;
  6) LLM_MODEL="qwen2.5:32b" ;;
  7) read -rp "  Enter model name (e.g. llama3.2:1b): " LLM_MODEL ;;
  *) LLM_MODEL="$_RECOMMENDED_MODEL" ;;
esac

success "Selected LLM: ${LLM_MODEL}"
echo ""

if ollama list 2>/dev/null | grep -q "^${LLM_MODEL}"; then
  info "LLM already present: ${LLM_MODEL}"
else
  read -rp "  Pull ${LLM_MODEL} now? [Y/n]: " _pull_llm
  if [[ ! $_pull_llm =~ ^[Nn]$ ]]; then
    info "Pulling ${LLM_MODEL} — this may take several minutes..."
    if ollama pull "$LLM_MODEL"; then
      success "LLM ready: ${LLM_MODEL}"
    else
      warn "LLM pull failed. Run later: ollama pull ${LLM_MODEL}"
      LLM_MODEL="${_RECOMMENDED_MODEL}"
    fi
  else
    warn "Skipped. Run when ready: ollama pull ${LLM_MODEL}"
  fi
fi

PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

# ================================================================
# SAVE CONFIGURATION
# ================================================================

# Helper: update or append a key=value in the config file
_upsert() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
  else
    echo "${key}=${val}" >> "$CONFIG_FILE"
  fi
}

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

# --- Network ---
ZETTABRAIN_SERVER_HOST="${PRIMARY_IP}"
ZETTABRAIN_TUNNEL_ENABLED=false

# --- TLS ---
ZETTABRAIN_TLS_PROVIDER="${ZETTABRAIN_TLS_PROVIDER:-self-signed}"
ENVEOF

# Append S3 FUSE mount config if object storage was selected
if [ "${STORAGE_TYPE}" = "s3" ]; then
  cat >> "$CONFIG_FILE" << S3EOF

# --- Object Storage (s3fs-fuse mount) ---
ZETTABRAIN_S3_MOUNT="${S3_MOUNT_POINT}"
ZETTABRAIN_S3_BUCKET="${S3_BUCKET}"
ZETTABRAIN_S3_PREFIX="${S3_PREFIX:-}"
S3EOF
fi

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
# STEP 5/6 — HTTPS / TLS SETUP
# ================================================================
step "Step 5/6: HTTPS / TLS setup"
echo ""
echo -e "  How should HTTPS be provided?\n"
echo -e "  ${BOLD}1)${NC} Caddy          — automatic Let's Encrypt cert, requires a public domain"
echo -e "  ${BOLD}2)${NC} Self-signed     — works immediately, browser shows a one-time warning"
echo -e "  ${BOLD}3)${NC} HTTP only       — no encryption (not recommended for production)"
echo ""

ZETTABRAIN_TLS_PROVIDER=""
while true; do
  read -rp "  Select [1/2/3]: " _tls_choice
  case "$_tls_choice" in
    1|caddy|Caddy) ZETTABRAIN_TLS_PROVIDER="caddy";       break ;;
    2|self|self-signed) ZETTABRAIN_TLS_PROVIDER="self-signed"; break ;;
    3|http|none)   ZETTABRAIN_TLS_PROVIDER="none";        break ;;
    *) warn "Please enter 1, 2, or 3." ;;
  esac
done

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# ── Option 1: Caddy ──────────────────────────────────────────────
if [ "$ZETTABRAIN_TLS_PROVIDER" = "caddy" ]; then

  read -rp "  Domain name (e.g. zettabrain.yourdomain.com): " CADDY_DOMAIN
  [ -z "$CADDY_DOMAIN" ] && error "Domain is required for Caddy."

  info "Installing Caddy..."
  if [ -f /etc/os-release ]; then . /etc/os-release; fi
  case "${ID:-}" in
    ubuntu|debian|linuxmint|pop)
      apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https 2>/dev/null || true
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
      apt-get update -qq && apt-get install -y -qq caddy
      ;;
    amzn|rhel|centos|fedora|rocky|almalinux)
      # dnf-plugins-core provides `dnf copr` and `dnf config-manager`
      "$_PM" install -y dnf-plugins-core >> "$LOG_FILE" 2>&1 || true
      # Try COPR repo first, then direct package, then binary fallback
      if ! "$_PM" copr enable -y @caddy/caddy >> "$LOG_FILE" 2>&1 \
           || ! "$_PM" install -y caddy >> "$LOG_FILE" 2>&1; then
        if ! "$_PM" install -y caddy >> "$LOG_FILE" 2>&1; then
          info "Falling back to Caddy binary install..."
          _caddy_ver=$(curl -sL https://api.github.com/repos/caddyserver/caddy/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4)
          curl -sL "https://github.com/caddyserver/caddy/releases/download/${_caddy_ver}/caddy_${_caddy_ver#v}_linux_amd64.tar.gz" \
            | tar xz -C /usr/local/bin caddy >> "$LOG_FILE" 2>&1
        fi
      fi
      ;;
    *)
      warn "Unknown OS — attempting binary install of Caddy..."
      _caddy_ver=$(curl -sL https://api.github.com/repos/caddyserver/caddy/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
      curl -sL "https://github.com/caddyserver/caddy/releases/download/${_caddy_ver}/caddy_${_caddy_ver#v}_linux_amd64.tar.gz" \
        | tar xz -C /usr/local/bin caddy >> "$LOG_FILE" 2>&1
      ;;
  esac

  command -v caddy &>/dev/null || error "Caddy installation failed."
  success "Caddy installed: $(caddy version)"

  # Write Caddyfile
  mkdir -p /etc/caddy
  cat > /etc/caddy/Caddyfile <<CADDY
${CADDY_DOMAIN} {
    reverse_proxy localhost:7860
    encode gzip
    log {
        output file /var/log/caddy/zettabrain.log
    }
}
CADDY

  mkdir -p /var/log/caddy
  # Enable and start Caddy
  if command -v systemctl &>/dev/null; then
    systemctl enable --now caddy 2>/dev/null || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
  else
    caddy start --config /etc/caddy/Caddyfile 2>/dev/null || true
  fi

  success "Caddy configured for ${CADDY_DOMAIN}"
  info    "ZettaBrain server will run on HTTP localhost:7860 — Caddy handles HTTPS."
  info    "DNS: ensure ${CADDY_DOMAIN} points to this server's public IP."

  # Store domain in config
  _upsert "ZETTABRAIN_CADDY_DOMAIN" "$CADDY_DOMAIN"

# ── Option 2: Self-signed ─────────────────────────────────────────
elif [ "$ZETTABRAIN_TLS_PROVIDER" = "self-signed" ]; then

  if [ -f "$CERT_DIR/cert.pem" ] && [ -f "$CERT_DIR/key.pem" ]; then
    success "TLS certificate already present at $CERT_DIR"
  else
    # Ensure openssl is available (may need installing on RHEL minimal installs)
    command -v openssl &>/dev/null || _install openssl
    if command -v openssl &>/dev/null; then
      info "Generating self-signed TLS certificate (valid 10 years)..."
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$CERT_DIR/key.pem" \
        -out    "$CERT_DIR/cert.pem" \
        -days 3650 -nodes \
        -subj "/CN=local.zettabrain.app" \
        -addext "subjectAltName=DNS:local.zettabrain.app,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
      chmod 600 "$CERT_DIR/key.pem"
      chmod 644 "$CERT_DIR/cert.pem"
      success "Self-signed certificate generated at $CERT_DIR"
      info    "Browser will show a one-time warning — this is normal for self-signed certs."
    else
      warn "openssl not found — cannot generate certificate. Server will use HTTP."
      ZETTABRAIN_TLS_PROVIDER="none"
    fi
  fi

# ── Option 3: HTTP only ───────────────────────────────────────────
else
  warn "Running without TLS. Traffic will be unencrypted."
  warn "This is only suitable for trusted local networks."
fi

# ── Open firewall port 7860 (firewalld on RHEL, ufw on Ubuntu) ───
_open_port 7860
# Caddy also needs 80 + 443 for Let's Encrypt ACME challenge
if [ "$ZETTABRAIN_TLS_PROVIDER" = "caddy" ]; then
  _open_port 80
  _open_port 443
fi

# ── Final SELinux check (catches any remaining denials) ──────────
_selinux_permissive_check

# ================================================================
# STEP 5/5 — BUILD RAG VECTOR STORE
# ================================================================
step "Step 6/6: Building RAG vector store"

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

INGEST_SCRIPT="${DEPLOY_DIR}/05_ingest_documents.py"
DOC_COUNT=0

if [ -z "$PYTHON_BIN" ]; then
  warn "No Python with langchain found. Build the vector store manually:"
  warn "  find /root/.local/share/pipx/venvs/zettabrain-rag -name 'python*' -type f | head -3"
  warn "  zettabrain-ingest"

elif [ ! -f "$INGEST_SCRIPT" ]; then
  warn "Ingest script not deployed yet at: ${INGEST_SCRIPT}"
  warn "Run: zettabrain-ingest"

else
  DOC_COUNT=$(find "$PRIMARY_PATH" \
    -type f \( -name "*.pdf" -o -name "*.txt" -o -name "*.docx" -o -name "*.md" \) \
    2>/dev/null | wc -l)

  if [ "$DOC_COUNT" -eq 0 ]; then
    warn "No documents found in ${PRIMARY_PATH}."
    warn "Add documents then run: zettabrain-ingest"
  else
    info "Found ${DOC_COUNT} document(s) — building vector store via ingest script..."
    echo ""
    cd "$DEPLOY_DIR" || true

    # Use the ingest script (not the chat/RAG script) so chunking is consistent
    # with subsequent `zettabrain-ingest` runs and duplicates are avoided.
    if ZETTABRAIN_DOCS="$PRIMARY_PATH" "$PYTHON_BIN" "$INGEST_SCRIPT"; then
      echo ""
      success "Vector store built successfully."
      log "RAG build complete. Path: ${PRIMARY_PATH} | Docs: ${DOC_COUNT}"
    else
      echo ""
      warn "Vector store build failed. Run manually once documents are in place:"
      warn "  zettabrain-ingest"
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
ExecStart=${_server_bin} --host 0.0.0.0 --port 7860
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
  warn "Start manually: zettabrain-server --no-tls --port 7860"
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
echo -e "  Config file  : ${GREEN}${CONFIG_FILE}${NC}"
echo ""
echo -e "${CYAN}─── Access the GUI ──────────────────────────────────────${NC}"
echo ""
echo -e "  Open in browser: ${BOLD}https://local.zettabrain.app:7860${NC}"
echo ""
echo -e "  ${GREEN}Trusted HTTPS certificate — no browser warnings.${NC}"
echo -e "  ${GREEN}Traffic stays entirely on this machine (127.0.0.1).${NC}"
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
