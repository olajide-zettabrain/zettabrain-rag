#!/usr/bin/env python3
"""
ZettaBrain — Customer Provisioning Tool
Run this once per new customer to create a Cloudflare Tunnel + DNS record.

Usage:
    python provision.py <customer-name>
    python provision.py acme-corp
    python provision.py list
    python provision.py revoke acme-corp

Requirements:
    pip install requests
    Set env vars (or edit CONFIG below):
        CF_API_TOKEN    — Cloudflare API token
        CF_ACCOUNT_ID   — Cloudflare account ID
        CF_ZONE_ID      — Zone ID for zettabrain.io
"""

import base64
import json
import os
import secrets
import sys
import time

try:
    import requests
except ImportError:
    print("ERROR: requests not installed. Run: pip install requests")
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────────
CONFIG = {
    "CF_API_TOKEN":  os.environ.get("CF_API_TOKEN",  ""),
    "CF_ACCOUNT_ID": os.environ.get("CF_ACCOUNT_ID", ""),
    "CF_ZONE_ID":    os.environ.get("CF_ZONE_ID",    ""),
    "DOMAIN":        "zettabrain.app",
    "LOCAL_SERVICE": "http://localhost:7860",
}
# ── End configuration ──────────────────────────────────────────────────────────


def _headers():
    return {
        "Authorization": f"Bearer {CONFIG['CF_API_TOKEN']}",
        "Content-Type": "application/json",
    }


def _check(resp, context=""):
    if not resp.ok:
        print(f"ERROR {context}: {resp.status_code} — {resp.text[:300]}")
        sys.exit(1)
    data = resp.json()
    if not data.get("success"):
        print(f"ERROR {context}: {json.dumps(data.get('errors'), indent=2)}")
        sys.exit(1)
    return data["result"]


def create_tunnel(customer_name: str):
    """Create a named Cloudflare Tunnel and return (tunnel_id, tunnel_secret)."""
    tunnel_secret_bytes = secrets.token_bytes(32)
    tunnel_secret_b64   = base64.b64encode(tunnel_secret_bytes).decode()

    result = _check(
        requests.post(
            f"https://api.cloudflare.com/client/v4/accounts/{CONFIG['CF_ACCOUNT_ID']}/cfd_tunnel",
            headers=_headers(),
            json={"name": f"zettabrain-{customer_name}", "tunnel_secret": tunnel_secret_b64},
        ),
        "create_tunnel",
    )
    return result["id"], tunnel_secret_b64


def configure_tunnel_ingress(tunnel_id: str, hostname: str):
    """Set the tunnel ingress rule: hostname → local service."""
    _check(
        requests.put(
            f"https://api.cloudflare.com/client/v4/accounts/{CONFIG['CF_ACCOUNT_ID']}/cfd_tunnel/{tunnel_id}/configurations",
            headers=_headers(),
            json={
                "config": {
                    "ingress": [
                        {"hostname": hostname, "service": CONFIG["LOCAL_SERVICE"]},
                        {"service": "http_status:404"},   # catch-all required by Cloudflare
                    ]
                }
            },
        ),
        "configure_ingress",
    )


def create_dns_record(tunnel_id: str, hostname: str):
    """Create a CNAME DNS record pointing the subdomain at the tunnel."""
    subdomain = hostname.split(".")[0]
    _check(
        requests.post(
            f"https://api.cloudflare.com/client/v4/zones/{CONFIG['CF_ZONE_ID']}/dns_records",
            headers=_headers(),
            json={
                "type":    "CNAME",
                "name":    subdomain,
                "content": f"{tunnel_id}.cfargotunnel.com",
                "proxied": True,
                "ttl":     1,
            },
        ),
        "create_dns",
    )


def build_token(account_tag: str, tunnel_id: str, tunnel_secret_b64: str) -> str:
    """
    Build the cloudflared service token.
    Format: base64(json({"a": account_tag, "t": tunnel_id, "s": tunnel_secret_b64}))
    """
    payload = json.dumps({"a": account_tag, "t": tunnel_id, "s": tunnel_secret_b64})
    return base64.b64encode(payload.encode()).decode()


def get_account_tag() -> str:
    result = _check(
        requests.get(
            f"https://api.cloudflare.com/client/v4/accounts/{CONFIG['CF_ACCOUNT_ID']}",
            headers=_headers(),
        ),
        "get_account",
    )
    return result["id"]


def cmd_provision(customer_name: str):
    hostname = f"{customer_name}.{CONFIG['DOMAIN']}"

    print(f"\n  Provisioning tunnel for: {customer_name}")
    print(f"  Public URL will be     : https://{hostname}\n")

    print("  [1/4] Creating Cloudflare Tunnel...")
    tunnel_id, tunnel_secret = create_tunnel(customer_name)
    print(f"        Tunnel ID: {tunnel_id}")

    print("  [2/4] Configuring tunnel ingress rule...")
    configure_tunnel_ingress(tunnel_id, hostname)

    print("  [3/4] Creating DNS record...")
    create_dns_record(tunnel_id, hostname)

    print("  [4/4] Building customer token...")
    account_tag = get_account_tag()
    token = build_token(account_tag, tunnel_id, tunnel_secret)

    print(f"""
╔══════════════════════════════════════════════════════════╗
║           Provisioning Complete!                         ║
╚══════════════════════════════════════════════════════════╝

  Customer   : {customer_name}
  Public URL : https://{hostname}
  Tunnel ID  : {tunnel_id}

  ── Token to send to customer ─────────────────────────────

  {token}

  ── What customer does ────────────────────────────────────

  pipx install zettabrain-rag
  sudo zettabrain-setup
  # When prompted for tunnel token, paste the token above.

""")


def cmd_list():
    result = _check(
        requests.get(
            f"https://api.cloudflare.com/client/v4/accounts/{CONFIG['CF_ACCOUNT_ID']}/cfd_tunnel"
            "?is_deleted=false&per_page=50",
            headers=_headers(),
        ),
        "list_tunnels",
    )
    if not result:
        print("  No active tunnels.")
        return
    print(f"\n  {'NAME':<35} {'TUNNEL ID':<40} {'STATUS'}")
    print(f"  {'─'*35} {'─'*40} {'─'*10}")
    for t in result:
        name   = t.get("name", "")
        tid    = t.get("id", "")
        status = t.get("status", "unknown")
        print(f"  {name:<35} {tid:<40} {status}")
    print()


def cmd_revoke(customer_name: str):
    tunnel_name = f"zettabrain-{customer_name}"

    # Find the tunnel
    result = _check(
        requests.get(
            f"https://api.cloudflare.com/client/v4/accounts/{CONFIG['CF_ACCOUNT_ID']}/cfd_tunnel"
            f"?name={tunnel_name}&is_deleted=false",
            headers=_headers(),
        ),
        "find_tunnel",
    )
    if not result:
        print(f"  No tunnel found for: {customer_name}")
        return

    tunnel_id = result[0]["id"]
    print(f"  Deleting tunnel {tunnel_id}...")
    _check(
        requests.delete(
            f"https://api.cloudflare.com/client/v4/accounts/{CONFIG['CF_ACCOUNT_ID']}/cfd_tunnel/{tunnel_id}",
            headers=_headers(),
        ),
        "delete_tunnel",
    )

    # Delete DNS record
    hostname  = f"{customer_name}.{CONFIG['DOMAIN']}"
    dns_result = _check(
        requests.get(
            f"https://api.cloudflare.com/client/v4/zones/{CONFIG['CF_ZONE_ID']}/dns_records"
            f"?name={hostname}",
            headers=_headers(),
        ),
        "find_dns",
    )
    for rec in dns_result:
        requests.delete(
            f"https://api.cloudflare.com/client/v4/zones/{CONFIG['CF_ZONE_ID']}/dns_records/{rec['id']}",
            headers=_headers(),
        )
        print(f"  Deleted DNS record: {hostname}")

    print(f"\n  Revoked access for: {customer_name}\n")


def _validate_config():
    missing = [k for k in ("CF_API_TOKEN", "CF_ACCOUNT_ID", "CF_ZONE_ID") if not CONFIG[k]]
    if missing:
        print(f"\nERROR: Missing configuration: {', '.join(missing)}")
        print("\nSet environment variables before running:")
        print("  export CF_API_TOKEN=your_token")
        print("  export CF_ACCOUNT_ID=your_account_id")
        print("  export CF_ZONE_ID=your_zone_id")
        print("\nOr edit the CONFIG dict at the top of this file.\n")
        sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    _validate_config()

    cmd = sys.argv[1].lower()

    if cmd == "list":
        cmd_list()
    elif cmd == "revoke":
        if len(sys.argv) < 3:
            print("Usage: python provision.py revoke <customer-name>")
            sys.exit(1)
        cmd_revoke(sys.argv[2].lower().replace(" ", "-"))
    else:
        customer = cmd.lower().replace(" ", "-")
        cmd_provision(customer)


if __name__ == "__main__":
    main()
