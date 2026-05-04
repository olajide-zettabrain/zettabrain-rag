#!/usr/bin/env bash
# ZettaBrain — Let's Encrypt wildcard certificate setup
# Supports GoDaddy and Cloudflare via DNS-01 challenge
set -euo pipefail

BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "[${GREEN}OK${NC}]    $*"; }
warn() { echo -e "[${YELLOW}WARN${NC}]  $*"; }
error(){ echo -e "\n[${RED}ERROR${NC}] $*\n"; exit 1; }
step() { echo -e "\n${BOLD}── $* ──${NC}"; }

CONFIG_FILE="/opt/zettabrain/src/zettabrain.env"
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
SECRETS_DIR="/root/.secrets"

[ "$(id -u)" = "0" ] || error "Run as root: sudo zettabrain-cert"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ZettaBrain — Let's Encrypt Certificate Setup      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Domain ────────────────────────────────────────────────────────────────
step "Domain"
read -rp "  Root domain (e.g. zettabrain.io): " DOMAIN
[ -z "$DOMAIN" ] && error "Domain is required"
WILDCARD="*.${DOMAIN}"

read -rp "  Admin email for Let's Encrypt notifications: " LE_EMAIL
[ -z "$LE_EMAIL" ] && error "Email is required"

# ── DNS provider ──────────────────────────────────────────────────────────
step "DNS Provider"
echo "  1) GoDaddy"
echo "  2) Cloudflare"
read -rp "  Select [1/2]: " _dns

case "$_dns" in
  1|godaddy|GoDaddy)
    step "GoDaddy API Credentials"
    echo "  Generate at: https://developer.godaddy.com/keys  (Production environment)"
    read -rp  "  API Key:    " GODADDY_KEY
    read -rsp "  API Secret: " GODADDY_SECRET
    echo ""
    [ -z "$GODADDY_KEY" ] && error "API Key is required"
    [ -z "$GODADDY_SECRET" ] && error "API Secret is required"

    step "Installing certbot + certbot-dns-godaddy"
    pip3 install --quiet certbot certbot-dns-godaddy || \
      pip  install --quiet certbot certbot-dns-godaddy

    CREDS_FILE="${SECRETS_DIR}/godaddy.ini"
    mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
    printf "dns_godaddy_key    = %s\ndns_godaddy_secret = %s\n" \
      "$GODADDY_KEY" "$GODADDY_SECRET" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    ok "Credentials saved to $CREDS_FILE"

    CERTBOT_ARGS=(
      certonly
      --authenticator dns-godaddy
      --dns-godaddy-credentials "$CREDS_FILE"
      --dns-godaddy-propagation-seconds 90
      -d "$WILDCARD"
      -d "$DOMAIN"
      --non-interactive --agree-tos
      --email "$LE_EMAIL" --no-eff-email
    )
    ;;

  2|cloudflare|Cloudflare)
    step "Cloudflare API Credentials"
    echo "  Create a token with Zone:DNS:Edit permission at: https://dash.cloudflare.com/profile/api-tokens"
    read -rsp "  API Token: " CF_TOKEN
    echo ""
    [ -z "$CF_TOKEN" ] && error "API Token is required"

    step "Installing certbot + certbot-dns-cloudflare"
    pip3 install --quiet certbot certbot-dns-cloudflare || \
      pip  install --quiet certbot certbot-dns-cloudflare

    CREDS_FILE="${SECRETS_DIR}/cloudflare.ini"
    mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
    printf "dns_cloudflare_api_token = %s\n" "$CF_TOKEN" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    ok "Credentials saved to $CREDS_FILE"

    CERTBOT_ARGS=(
      certonly
      --authenticator dns-cloudflare
      --dns-cloudflare-credentials "$CREDS_FILE"
      --dns-cloudflare-propagation-seconds 30
      -d "$WILDCARD"
      -d "$DOMAIN"
      --non-interactive --agree-tos
      --email "$LE_EMAIL" --no-eff-email
    )
    ;;

  *)
    error "Invalid selection — choose 1 or 2"
    ;;
esac

# ── Issue certificate ──────────────────────────────────────────────────────
step "Requesting wildcard certificate for ${WILDCARD} and ${DOMAIN}"
certbot "${CERTBOT_ARGS[@]}"

# ── Verify ────────────────────────────────────────────────────────────────
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

[ -f "$CERT_PATH" ] || error "Certificate not found at ${CERT_PATH} — check certbot output above"
ok "Certificate issued: ${CERT_PATH}"

# ── Fingerprint ───────────────────────────────────────────────────────────
FINGERPRINT=$(openssl x509 -in "$CERT_PATH" -noout -fingerprint -sha256 2>/dev/null \
  | sed 's/SHA256 Fingerprint=/sha256 Fingerprint=/')

# ── Update zettabrain.env ──────────────────────────────────────────────────
step "Updating ZettaBrain configuration"

_upsert() {
  local key="$1" val="$2"
  if [ -f "$CONFIG_FILE" ] && grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
  else
    echo "${key}=${val}" >> "$CONFIG_FILE"
  fi
}

_upsert "ZETTABRAIN_CERT"            "$CERT_PATH"
_upsert "ZETTABRAIN_KEY"             "$KEY_PATH"
_upsert "ZETTABRAIN_TLS_FINGERPRINT" "$FINGERPRINT"
_upsert "ZETTABRAIN_SERVER_HOST"     "$DOMAIN"
_upsert "ZETTABRAIN_TLS_TYPE"        "letsencrypt"
ok "Updated $CONFIG_FILE"

# ── Renewal hook ───────────────────────────────────────────────────────────
step "Installing auto-renewal hook"
mkdir -p "$HOOK_DIR"
cat > "${HOOK_DIR}/zettabrain.sh" <<'HOOK'
#!/usr/bin/env bash
# Runs after every successful certbot renewal
CONFIG_FILE="/opt/zettabrain/src/zettabrain.env"
CERT=$(grep "^ZETTABRAIN_CERT=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
[ -f "$CERT" ] || exit 0
FP=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 \
     | sed 's/SHA256 Fingerprint=/sha256 Fingerprint=/')
sed -i "s|^ZETTABRAIN_TLS_FINGERPRINT=.*|ZETTABRAIN_TLS_FINGERPRINT=${FP}|" "$CONFIG_FILE"
echo "[OK] ZettaBrain: TLS fingerprint updated after cert renewal"
HOOK
chmod +x "${HOOK_DIR}/zettabrain.sh"
ok "Renewal hook installed: ${HOOK_DIR}/zettabrain.sh"

# ── Dry-run renewal test ───────────────────────────────────────────────────
step "Testing auto-renewal (dry run)"
if certbot renew --dry-run --quiet 2>&1; then
  ok "Auto-renewal working correctly"
else
  warn "Dry-run renewal failed — check: certbot renew --dry-run"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║            Certificate Setup Complete                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Domain      : ${DOMAIN}"
echo "  Wildcard    : ${WILDCARD}"
echo "  Certificate : ${CERT_PATH}"
echo "  Key         : ${KEY_PATH}"
printf  "  Expires     : %s\n" "$(openssl x509 -in "$CERT_PATH" -noout -enddate | cut -d= -f2)"
echo "  Renewal     : automatic (certbot systemd timer or cron)"
echo ""
echo "  Restart the server to apply:"
echo "    pkill -f zettabrain-server"
echo "    zettabrain-server --port 443"
echo ""
