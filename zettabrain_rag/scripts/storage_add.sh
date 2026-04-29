#!/bin/bash
# ============================================================
# ZettaBrain — Add Storage Source
# ============================================================
# Run after initial setup to connect additional document stores.
# Invoked by: sudo zettabrain-storage add
# ============================================================

DEPLOY_DIR="/opt/zettabrain/src"
CONFIG_FILE="${DEPLOY_DIR}/zettabrain.env"
STORAGE_CONFIG="${DEPLOY_DIR}/storage.conf"
LOG_FILE="/var/log/zettabrain-setup.log"
FSTAB_FILE="/etc/fstab"
NFS_OPTS="defaults,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"
SMB_OPTS="uid=0,gid=0,file_mode=0755,dir_mode=0755,noperm,_netdev"

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

if [ "$EUID" -ne 0 ]; then
  error "Run as root: sudo zettabrain-storage add"
  exit 1
fi

clear 2>/dev/null || true
echo ""
echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}${BOLD}║        ZettaBrain — Add Storage Source               ║${NC}"
echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# Show existing storage sources
if [ -f "$STORAGE_CONFIG" ]; then
  echo -e "  ${CYAN}Current storage sources:${NC}"
  grep -v "^#" "$STORAGE_CONFIG" | while IFS='|' read -r _role _type _label _path; do
    echo -e "  [${_role}] ${_type^^} → ${_path}"
  done
  echo ""
fi

# Select type
echo -e "  Storage type to add:\n"
echo -e "  ${BOLD}1)${NC} Local folder"
echo -e "  ${BOLD}2)${NC} NFS share"
echo -e "  ${BOLD}3)${NC} SMB / CIFS share"
echo ""

ADD_TYPE=""
while true; do
  read -rp "  Select [1/2/3]: " _choice
  case "$_choice" in
    1|local) ADD_TYPE="local"; break ;;
    2|nfs)   ADD_TYPE="nfs";   break ;;
    3|smb)   ADD_TYPE="smb";   break ;;
    *) warn "Enter 1, 2, or 3." ;;
  esac
done

NEW_PATH=""
NEW_LABEL=""

# ── LOCAL ─────────────────────────────────
if [ "$ADD_TYPE" = "local" ]; then
  while true; do
    read -rp "  Folder path: " _path
    if [ -d "$_path" ]; then
      NEW_PATH="$_path"
      NEW_LABEL="local:${_path}"
      break
    else
      read -rp "  Path does not exist. Create it? [Y/n]: " _c
      if [[ ! $_c =~ ^[Nn]$ ]]; then
        mkdir -p "$_path" && NEW_PATH="$_path" && NEW_LABEL="local:${_path}" && break
      fi
    fi
  done
fi

# ── NFS ───────────────────────────────────
if [ "$ADD_TYPE" = "nfs" ]; then
  while true; do
    read -rp "  NFS Server IP: " _ip
    [[ $_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
    warn "Invalid IP."
  done
  while true; do
    read -rp "  NFS export path: " _export
    [[ $_export == /* ]] && break
    warn "Must start with /"
  done
  _mp="/mnt/zettabrain-nfs-$(date +%s)"
  read -rp "  Local mount point [${_mp}]: " _custom
  [ -n "$_custom" ] && _mp="$_custom"

  nc -zw5 "$_ip" 2049 &>/dev/null && success "Port 2049 open." || warn "Port check failed — attempting mount anyway."
  mkdir -p "$_mp"
  if mount -t nfs -o "$NFS_OPTS" "${_ip}:${_export}" "$_mp"; then
    success "Mounted at ${_mp}"
    NEW_PATH="$_mp"
    NEW_LABEL="nfs:${_ip}:${_export}"
    _fstab="${_ip}:${_export}  ${_mp}  nfs  ${NFS_OPTS}  0  0"
    grep -qF "${_ip}:${_export}" "$FSTAB_FILE" 2>/dev/null || \
      { echo ""; echo "# ZettaBrain NFS extra — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$_fstab"; } >> "$FSTAB_FILE"
    systemctl daemon-reload 2>/dev/null || true
  else
    error "Mount failed."; exit 1
  fi
fi

# ── SMB ───────────────────────────────────
if [ "$ADD_TYPE" = "smb" ]; then
  while true; do
    read -rp "  SMB Server IP: " _ip
    [[ $_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
    warn "Invalid IP."
  done
  while true; do
    read -rp "  SMB share name: " _share
    [ -n "$_share" ] && break
  done
  read -rp "  Username [blank for guest]: " _user
  _pass=""
  _domain=""
  if [ -n "$_user" ]; then
    read -rsp "  Password: " _pass; echo ""
    read -rp "  Domain [blank if not needed]: " _domain
  fi
  _mp="/mnt/zettabrain-smb-$(date +%s)"
  read -rp "  Local mount point [${_mp}]: " _custom
  [ -n "$_custom" ] && _mp="$_custom"

  _creds="/etc/zettabrain/smb-${_ip}-extra.credentials"
  mkdir -p /etc/zettabrain
  { echo "username=${_user:-guest}"; [ -n "$_pass" ] && echo "password=${_pass}"; [ -n "$_domain" ] && echo "domain=${_domain}"; } > "$_creds"
  chmod 600 "$_creds"
  _mopts="${SMB_OPTS},credentials=${_creds}"

  mkdir -p "$_mp"
  nc -zw5 "$_ip" 445 &>/dev/null && success "Port 445 open." || warn "Port check failed — attempting mount anyway."
  if mount -t cifs "//${_ip}/${_share}" "$_mp" -o "$_mopts"; then
    success "Mounted at ${_mp}"
    NEW_PATH="$_mp"
    NEW_LABEL="smb://${_ip}/${_share}"
    _fstab="//${_ip}/${_share}  ${_mp}  cifs  ${_mopts}  0  0"
    grep -qF "//${_ip}/${_share}" "$FSTAB_FILE" 2>/dev/null || \
      { echo ""; echo "# ZettaBrain SMB extra — $(date '+%Y-%m-%d %H:%M:%S')"; echo "$_fstab"; } >> "$FSTAB_FILE"
    systemctl daemon-reload 2>/dev/null || true
  else
    error "SMB mount failed."; exit 1
  fi
fi

# Append to storage registry
echo "extra|${ADD_TYPE}|${NEW_LABEL}|${NEW_PATH}" >> "$STORAGE_CONFIG"
success "Storage source registered: ${NEW_LABEL}"

# Ask to ingest now
echo ""
read -rp "  Ingest documents from ${NEW_PATH} now? [Y/n]: " _ingest
if [[ ! $_ingest =~ ^[Nn]$ ]]; then
  _py=$(find /root/.local/share/pipx/venvs/zettabrain-rag -name "python3" -type f 2>/dev/null | head -1)
  _script="${DEPLOY_DIR}/05_ingest_documents.py"
  if [ -f "$_script" ] && [ -n "$_py" ]; then
    "$_py" "$_script" --folder "$NEW_PATH"
    success "Ingestion complete."
  else
    warn "Run manually: zettabrain-ingest --folder ${NEW_PATH}"
  fi
fi

echo ""
success "Done. New storage source: ${NEW_LABEL} → ${NEW_PATH}"
echo ""
echo -e "  ${CYAN}Ingest at any time:${NC} ${YELLOW}zettabrain-ingest --folder ${NEW_PATH}${NC}"
echo ""
