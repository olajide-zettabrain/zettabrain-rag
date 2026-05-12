#!/usr/bin/env python3
"""
ZettaBrain LinkedIn Manager
────────────────────────────
Commands:
  python3 scripts/linkedin.py auth          # OAuth flow — saves token
  python3 scripts/linkedin.py about         # Update company About section
  python3 scripts/linkedin.py post          # Publish all pre-drafted posts
  python3 scripts/linkedin.py post --msg "Text"  # Publish a single custom post

Required env vars (set in .env or export):
  LINKEDIN_CLIENT_ID
  LINKEDIN_CLIENT_SECRET

Optional:
  LINKEDIN_TOKEN_FILE   path to token cache (default: ~/.zettabrain/linkedin_token.json)

Setup:
  1. Go to https://www.linkedin.com/developers/apps and create an app.
  2. Add products: "Share on LinkedIn" and "Marketing Developer Platform".
  3. Under Auth, set redirect URL to: http://localhost:8080/callback
  4. Copy Client ID and Secret → export as env vars (or add to .env).
  5. Run: python3 scripts/linkedin.py auth
  6. Run: python3 scripts/linkedin.py post
"""

import argparse
import json
import os
import sys
import time
import threading
import webbrowser
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

import requests

# ── Constants ────────────────────────────────────────────────────
ORG_ID          = "107995733"
ORG_URN         = f"urn:li:organization:{ORG_ID}"
AUTH_URL        = "https://www.linkedin.com/oauth/v2/authorization"
TOKEN_URL       = "https://www.linkedin.com/oauth/v2/accessToken"
API_BASE        = "https://api.linkedin.com/v2"
REDIRECT_URI    = "http://localhost:8080/callback"
SCOPES          = "w_organization_social rw_organization_admin r_organization_social"
DEFAULT_TOKEN_FILE = Path.home() / ".zettabrain" / "linkedin_token.json"

# ── Pre-drafted posts ────────────────────────────────────────────
POSTS = [
    {
        "id": "product-intro",
        "text": (
            "Introducing ZettaBrain RAG 🧠\n\n"
            "A fully local AI document assistant — chat with your own PDFs, Word docs, "
            "and text files using a private LLM running on your own machine.\n\n"
            "No API keys. No cloud. No data leaving your infrastructure.\n\n"
            "✅ Runs on Linux, macOS (Apple Silicon & Intel), and Windows\n"
            "✅ Web GUI with streaming chat over HTTPS\n"
            "✅ Supports local disk, NFS, SMB, and S3 storage\n"
            "✅ GPU-accelerated on NVIDIA and Apple Silicon (Metal)\n"
            "✅ One-line install\n\n"
            "curl -fsSL https://zettabrain.app/install.sh | bash\n\n"
            "Built for teams handling sensitive documents — legal, finance, healthcare, "
            "research — where sending data to OpenAI or Anthropic isn't an option.\n\n"
            "Open source (MIT) · v0.5.21 now on PyPI\n\n"
            "👉 https://zettabrain.io\n"
            "📦 https://pypi.org/project/zettabrain-rag\n\n"
            "#PrivateAI #LocalLLM #RAG #OpenSource #Ollama #LangChain #AIPrivacy #ZettaBrain"
        ),
    },
    {
        "id": "openclaw-launch",
        "text": (
            "ZettaBrain RAG is now a verified skill on OpenClaw 🎉\n\n"
            "OpenClaw is a personal AI agent platform connecting AI assistants to tools "
            "and services. Our skill lets any OpenClaw agent chat with your private "
            "documents using ZettaBrain's fully local RAG pipeline — no data leaves your machine.\n\n"
            "What the skill enables:\n"
            "🔍 Ask questions across your document library\n"
            "📄 Works with PDF, DOCX, TXT, and Markdown\n"
            "🔒 Fully on-device by default (local storage + local Ollama)\n"
            "🛠️ Simple setup with clear service management and uninstall docs\n\n"
            "Find it on ClawHub 👇\n"
            "clawhub.ai/zettabrain/zettabrain-rag\n\n"
            "Or install directly:\n"
            "pipx install zettabrain-rag\n\n"
            "#OpenClaw #ClawHub #PrivateAI #LocalLLM #RAG #AISkills #ZettaBrain #OpenSource"
        ),
    },
    {
        "id": "macos-ec2",
        "text": (
            "ZettaBrain RAG now runs on AWS EC2 Mac 🍎\n\n"
            "As of v0.5.21, our setup wizard fully supports macOS — including Apple "
            "Silicon EC2 instances (mac2.metal M1/M2).\n\n"
            "What's new on macOS:\n"
            "⚡ Ollama uses Metal GPU acceleration (Apple Silicon unified memory)\n"
            "🍺 Homebrew-based install — no root required for the package step\n"
            "🔄 Registered as a launchd service — auto-starts on boot, easy to stop\n"
            "📁 Supports local, NFS, SMB, and S3 document storage\n\n"
            "Test your RAG deployment on a clean macOS environment before rolling out "
            "to production — EC2 Mac makes this easy.\n\n"
            "Upgrade: pipx upgrade zettabrain-rag\n"
            "Docs: github.com/zettabrain/zettabrain-rag\n\n"
            "#AWS #EC2Mac #AppleSilicon #macOS #PrivateAI #RAG #ZettaBrain #MLOps"
        ),
    },
]

ABOUT_TEXT = (
    "ZettaBrain is a private AI company building local-first document intelligence "
    "tools for teams and individuals who can't send data to the cloud.\n\n"
    "Our flagship product, ZettaBrain RAG, is an open-source AI document assistant "
    "that runs entirely on your own infrastructure — no API keys, no data leaving "
    "your machine, no subscriptions. It combines Ollama (local LLMs), ChromaDB "
    "(vector search), and LangChain into a single install with a secure web GUI.\n\n"
    "ZettaBrain works on Linux servers, macOS (including AWS EC2 Mac with Apple "
    "Silicon), and Windows — with support for local disk, NFS, SMB, and S3-compatible storage.\n\n"
    "Try it: https://zettabrain.io\n"
    "Install: pip install zettabrain-rag\n"
    "GitHub: github.com/zettabrain/zettabrain-rag"
)

# ── Helpers ──────────────────────────────────────────────────────
def _token_file():
    path = Path(os.environ.get("LINKEDIN_TOKEN_FILE", DEFAULT_TOKEN_FILE))
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def _load_token():
    f = _token_file()
    if f.exists():
        data = json.loads(f.read_text())
        if data.get("expires_at", 0) > time.time():
            return data["access_token"]
    return None


def _save_token(token_data):
    data = {
        "access_token": token_data["access_token"],
        "expires_at": time.time() + token_data.get("expires_in", 5184000),
    }
    _token_file().write_text(json.dumps(data, indent=2))
    _token_file().chmod(0o600)
    print(f"  Token saved → {_token_file()}")


def _require_creds():
    client_id = os.environ.get("LINKEDIN_CLIENT_ID")
    client_secret = os.environ.get("LINKEDIN_CLIENT_SECRET")
    if not client_id or not client_secret:
        print("ERROR: Set LINKEDIN_CLIENT_ID and LINKEDIN_CLIENT_SECRET env vars.")
        print("  export LINKEDIN_CLIENT_ID=your_id")
        print("  export LINKEDIN_CLIENT_SECRET=your_secret")
        sys.exit(1)
    return client_id, client_secret


def _headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "X-Restli-Protocol-Version": "2.0.0",
    }


# ── OAuth flow ───────────────────────────────────────────────────
def cmd_auth(_args):
    client_id, client_secret = _require_creds()

    # Local callback server to capture the auth code
    code_holder = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            qs = parse_qs(urllib.parse.urlparse(self.path).query)
            if "code" in qs:
                code_holder["code"] = qs["code"][0]
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"<h2>ZettaBrain: authentication successful! Close this tab.</h2>")
            else:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"Missing code parameter.")

        def log_message(self, *args):
            pass

    server = HTTPServer(("localhost", 8080), Handler)
    thread = threading.Thread(target=server.handle_request)
    thread.start()

    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPES,
    }
    url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"
    print(f"\n  Opening browser for LinkedIn OAuth…\n  {url}\n")
    webbrowser.open(url)
    thread.join(timeout=120)
    server.server_close()

    if "code" not in code_holder:
        print("ERROR: No code received within 120 seconds.")
        sys.exit(1)

    # Exchange code for token
    resp = requests.post(TOKEN_URL, data={
        "grant_type": "authorization_code",
        "code": code_holder["code"],
        "redirect_uri": REDIRECT_URI,
        "client_id": client_id,
        "client_secret": client_secret,
    })
    resp.raise_for_status()
    _save_token(resp.json())
    print("  Authentication successful.")


# ── Update About section ─────────────────────────────────────────
def cmd_about(args):
    token = _load_token()
    if not token:
        print("ERROR: No valid token. Run: python3 scripts/linkedin.py auth")
        sys.exit(1)

    text = getattr(args, "msg", None) or ABOUT_TEXT

    # LinkedIn requires Marketing Developer Platform for org profile updates
    resp = requests.post(
        f"{API_BASE}/organizationalEntityAcls?q=roleAssignee",
        headers=_headers(token),
    )

    resp = requests.patch(
        f"https://api.linkedin.com/rest/organizations/{ORG_ID}",
        headers={**_headers(token), "LinkedIn-Version": "202308"},
        json={"patch": {"$set": {"description": text}}},
    )
    if resp.status_code in (200, 204):
        print("  About section updated.")
    else:
        print(f"  ERROR {resp.status_code}: {resp.text}")
        print("  Note: updating the About section requires the Marketing Developer Platform product on your LinkedIn app.")


# ── Create a single post ─────────────────────────────────────────
def _create_post(token, text):
    payload = {
        "author": ORG_URN,
        "lifecycleState": "PUBLISHED",
        "specificContent": {
            "com.linkedin.ugc.ShareContent": {
                "shareCommentary": {"text": text},
                "shareMediaCategory": "NONE",
            }
        },
        "visibility": {
            "com.linkedin.ugc.MemberNetworkVisibility": "PUBLIC"
        },
    }
    resp = requests.post(f"{API_BASE}/ugcPosts", headers=_headers(token), json=payload)
    resp.raise_for_status()
    post_id = resp.headers.get("x-restli-id", resp.json().get("id", "unknown"))
    return post_id


def cmd_post(args):
    token = _load_token()
    if not token:
        print("ERROR: No valid token. Run: python3 scripts/linkedin.py auth")
        sys.exit(1)

    # Single custom post
    if getattr(args, "msg", None):
        post_id = _create_post(token, args.msg)
        print(f"  Posted: {post_id}")
        return

    # All pre-drafted posts
    for p in POSTS:
        print(f"  Publishing [{p['id']}]…", end=" ", flush=True)
        try:
            post_id = _create_post(token, p["text"])
            print(f"✓  id={post_id}")
        except requests.HTTPError as e:
            print(f"✗  {e.response.status_code}: {e.response.text}")
        time.sleep(2)  # avoid rate limiting


# ── CLI entry point ──────────────────────────────────────────────
def main():
    # Load .env if present
    env_file = Path(__file__).parent.parent / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

    parser = argparse.ArgumentParser(prog="linkedin", description="ZettaBrain LinkedIn Manager")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("auth", help="OAuth 2.0 login — opens browser, saves token")

    p_about = sub.add_parser("about", help="Update company About section")
    p_about.add_argument("--msg", help="Custom about text (default: pre-drafted)")

    p_post = sub.add_parser("post", help="Publish posts to the company page")
    p_post.add_argument("--msg", help="Custom post text (default: publishes all pre-drafted posts)")

    args = parser.parse_args()
    {"auth": cmd_auth, "about": cmd_about, "post": cmd_post}[args.cmd](args)


if __name__ == "__main__":
    main()
