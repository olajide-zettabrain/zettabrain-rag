"""
ZettaBrain RAG — CLI entry points v0.2.0
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__

PKG_DIR     = Path(__file__).parent
SCRIPTS_DIR = PKG_DIR / "scripts"
SETUP_SCRIPT       = SCRIPTS_DIR / "setup.sh"
STORAGE_ADD_SCRIPT = SCRIPTS_DIR / "storage_add.sh"
DEPLOY_DIR  = Path("/opt/zettabrain/src")
CERT_DIR    = Path("/opt/zettabrain/certs")
CONFIG_FILE = DEPLOY_DIR / "zettabrain.env"

DEPLOY_SCRIPTS = [
    "03_langchain_rag.py",
    "05_ingest_documents.py",
    "01_chromadb_setup.py",
    "02_embeddings_test.py",
]


def _deploy_scripts():
    try:
        DEPLOY_DIR.mkdir(parents=True, exist_ok=True)
    except PermissionError:
        return
    for name in DEPLOY_SCRIPTS:
        src  = SCRIPTS_DIR / name
        dest = DEPLOY_DIR  / name
        if src.exists():
            shutil.copy2(src, dest)  # always overwrite so upgrades take effect
            dest.chmod(0o755)


def _find_script(name: str) -> Path:
    for p in [DEPLOY_DIR / name, SCRIPTS_DIR / name]:
        if p.exists():
            return p
    return DEPLOY_DIR / name


def _find_python() -> str:
    venv = os.environ.get("VIRTUAL_ENV")
    if venv:
        p = Path(venv) / "bin" / "python3"
        if p.exists():
            return str(p)
    return sys.executable


def _load_config() -> dict:
    cfg = {}
    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"')
    return cfg


def _require(path: Path):
    if not path.exists():
        print(f"ERROR: Script not found: {path}")
        print("Try: pipx reinstall zettabrain-rag")
        sys.exit(1)


def _banner():
    print(f"\n╔══════════════════════════════════════════════════════╗")
    print(f"║        ZettaBrain RAG  v{__version__:<29}║")
    print(f"║  Local private AI — your data stays on device       ║")
    print(f"╚══════════════════════════════════════════════════════╝\n")


# -------------------------------------------------------
# zettabrain
# -------------------------------------------------------
def main():
    _deploy_scripts()
    _banner()
    parser = argparse.ArgumentParser(
        prog="zettabrain",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  sudo zettabrain-setup    Storage wizard (Local/NFS/SMB) + TLS cert + vector store
  zettabrain-ingest        Ingest documents into the vector store
  zettabrain-chat          Start interactive RAG chat (CLI)
  zettabrain-server        Launch secure HTTPS web GUI
  zettabrain-status        Show install info and vector store statistics
        """
    )
    parser.add_argument("--version", action="version",
                        version=f"zettabrain-rag {__version__}")
    parser.parse_args()


# -------------------------------------------------------
# zettabrain-setup
# -------------------------------------------------------
def setup_cmd():
    _deploy_scripts()
    _banner()
    _require(SETUP_SCRIPT)

    if os.geteuid() != 0:
        print("ERROR: Storage setup requires root privileges.")
        print("Run:   sudo zettabrain-setup\n")
        sys.exit(1)

    SETUP_SCRIPT.chmod(0o755)
    result = subprocess.run(["bash", str(SETUP_SCRIPT)])
    sys.exit(result.returncode)


# -------------------------------------------------------
# zettabrain-ingest
# -------------------------------------------------------
def ingest_cmd():
    _deploy_scripts()
    _banner()
    script = _find_script("05_ingest_documents.py")
    _require(script)

    parser = argparse.ArgumentParser(prog="zettabrain-ingest")
    parser.add_argument("--folder",  default=None,        help="Documents folder")
    parser.add_argument("--file",    default=None,        help="Single file to ingest")
    parser.add_argument("--clear",   action="store_true", help="Clear vector store")
    parser.add_argument("--stats",   action="store_true", help="Show stats")
    parser.add_argument("--rebuild", action="store_true", help="Force full rebuild")
    args, _ = parser.parse_known_args()

    cmd = [_find_python(), str(script)]
    if args.folder:  cmd += ["--folder", args.folder]
    if args.file:    cmd += ["--file",   args.file]
    if args.clear:   cmd += ["--clear"]
    if args.stats:   cmd += ["--stats"]

    os.chdir(DEPLOY_DIR)
    sys.exit(subprocess.run(cmd).returncode)


# -------------------------------------------------------
# zettabrain-chat
# -------------------------------------------------------
def chat_cmd():
    _deploy_scripts()
    _banner()
    script = _find_script("03_langchain_rag.py")
    _require(script)

    parser = argparse.ArgumentParser(prog="zettabrain-chat")
    parser.add_argument("--rebuild", action="store_true")
    parser.add_argument("--debug",   action="store_true")
    args, _ = parser.parse_known_args()

    cmd = [_find_python(), str(script)]
    if args.rebuild: cmd += ["--rebuild"]
    if args.debug:   cmd += ["--debug"]

    os.chdir(DEPLOY_DIR)
    sys.exit(subprocess.run(cmd).returncode)


# -------------------------------------------------------
# zettabrain-server  (HTTPS GUI)
# -------------------------------------------------------
def server_cmd():
    import importlib.util
    _deploy_scripts()
    _banner()

    if importlib.util.find_spec("uvicorn") is None:
        print("ERROR: uvicorn not installed.")
        sys.exit(1)

    parser = argparse.ArgumentParser(prog="zettabrain-server",
                                     description="Launch the ZettaBrain HTTPS web GUI")
    parser.add_argument("--host",   default="0.0.0.0",  help="Bind host (default: 0.0.0.0)")
    parser.add_argument("--port",   default=7860, type=int, help="Port (default: 7860)")
    parser.add_argument("--no-tls", action="store_true",   help="Disable HTTPS (HTTP only)")
    parser.add_argument("--reload", action="store_true",   help="Dev mode: auto-reload")
    args, _ = parser.parse_known_args()

    cfg       = _load_config()
    cert_file = cfg.get("ZETTABRAIN_CERT", str(CERT_DIR / "cert.pem"))
    key_file  = cfg.get("ZETTABRAIN_KEY",  str(CERT_DIR / "key.pem"))
    host_ip   = cfg.get("ZETTABRAIN_SERVER_HOST", "localhost")

    use_tls = (not args.no_tls
               and Path(cert_file).exists()
               and Path(key_file).exists())

    proto = "https" if use_tls else "http"
    print(f"  Starting ZettaBrain GUI...")
    print(f"  Protocol  : {'HTTPS (secure)' if use_tls else 'HTTP (no TLS — run setup first)'}")
    print(f"  Open in browser:")
    print(f"    {proto}://{host_ip}:{args.port}")
    if args.host == "0.0.0.0":
        print(f"    {proto}://localhost:{args.port}")
    if use_tls:
        fingerprint = cfg.get("ZETTABRAIN_TLS_FINGERPRINT", "")
        print(f"\n  Certificate fingerprint (SHA-256):")
        print(f"    {fingerprint}")
        print(f"\n  Note: Accept the browser's self-signed certificate warning")
        print(f"  by clicking 'Advanced' → 'Proceed to site'")
    else:
        print(f"\n  WARNING: TLS not configured. Run 'sudo zettabrain-setup' first.")
    print(f"\n  Press Ctrl+C to stop.\n")

    import uvicorn
    uvicorn_kwargs = dict(
        app="zettabrain_rag.server:app",
        host=args.host,
        port=args.port,
        reload=args.reload,
        log_level="warning",
    )
    if use_tls:
        uvicorn_kwargs["ssl_certfile"] = cert_file
        uvicorn_kwargs["ssl_keyfile"]  = key_file

    uvicorn.run(**uvicorn_kwargs)




# -------------------------------------------------------
# zettabrain-storage
# -------------------------------------------------------
def storage_cmd():
    """Manage storage sources — add new ones after initial setup."""
    _deploy_scripts()
    _banner()

    parser = argparse.ArgumentParser(prog="zettabrain-storage")
    parser.add_argument("action", choices=["add", "list"], help="add: add new storage | list: show current sources")
    args, _ = parser.parse_known_args()

    if args.action == "list":
        storage_conf = DEPLOY_DIR / "storage.conf"
        if not storage_conf.exists():
            print("No storage sources configured. Run: sudo zettabrain-setup")
            return
        print("\nConfigured storage sources:\n")
        for line in storage_conf.read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split("|")
            if len(parts) >= 4:
                role, stype, label, path = parts[0], parts[1], parts[2], parts[3]
                print(f"  [{role.upper()}] {stype.upper()} → {path}")
                print(f"          label: {label}")
        print()

    elif args.action == "add":
        script = STORAGE_ADD_SCRIPT
        if not script.exists():
            # Try to find it in the package
            bundled = SCRIPTS_DIR / "storage_add.sh"
            if bundled.exists():
                script = bundled
            else:
                print(f"ERROR: storage_add.sh not found at {script}")
                sys.exit(1)

        if os.geteuid() != 0:
            print("ERROR: Adding storage requires root privileges.")
            print("Run:   sudo zettabrain-storage add\n")
            sys.exit(1)

        script.chmod(0o755)
        result = subprocess.run(["bash", str(script)])
        sys.exit(result.returncode)

# -------------------------------------------------------
# zettabrain-status
# -------------------------------------------------------
def status_cmd():
    _deploy_scripts()
    _banner()

    cfg = _load_config()

    print(f"Version      : {__version__}")
    print(f"Package dir  : {PKG_DIR}")
    print(f"Scripts dir  : {DEPLOY_DIR}")
    print(f"Setup script : {SETUP_SCRIPT} ({'found' if SETUP_SCRIPT.exists() else 'MISSING'})")
    print()

    print("Deployed scripts:")
    for name in DEPLOY_SCRIPTS:
        status = "found" if (DEPLOY_DIR / name).exists() else "MISSING"
        print(f"  {name:<35} {status}")
    print()

    if cfg:
        print("Configuration:")
        for k, v in cfg.items():
            if "PASSWORD" not in k and "KEY" not in k:
                print(f"  {k} = {v}")
        print()

    cert = Path(cfg.get("ZETTABRAIN_CERT", str(CERT_DIR / "cert.pem")))
    print(f"TLS Certificate : {cert} ({'found' if cert.exists() else 'MISSING — run sudo zettabrain-setup'})")
    if cert.exists():
        fp = cfg.get("ZETTABRAIN_TLS_FINGERPRINT", "")
        print(f"Fingerprint     : {fp}")
    print()

    chroma   = DEPLOY_DIR / "zettabrain_vectorstore"
    sqlite   = chroma / "chroma.sqlite3"
    ingest   = DEPLOY_DIR / "ingested_files.json"
    if sqlite.exists():
        size = sqlite.stat().st_size / (1024 * 1024)
        print(f"Vector store : {chroma} ({size:.1f} MB)")
        import json
        if ingest.exists():
            data = json.loads(ingest.read_text())
            print(f"Tracked files: {len(data)}")
            for fp in sorted(data):
                print(f"  - {Path(fp).name}")
    else:
        print("Vector store : not built — run: sudo zettabrain-setup")
    print()
