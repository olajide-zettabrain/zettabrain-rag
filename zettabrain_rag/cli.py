"""
ZettaBrain RAG — CLI entry points.

Installed commands:
  zettabrain          — help / version
  zettabrain-chat     — start interactive RAG chat
  zettabrain-ingest   — ingest documents
  zettabrain-setup    — NFS mount wizard
  zettabrain-status   — vector store statistics

On first run, all bundled scripts are automatically deployed
to /opt/zettabrain/src so they are available to the CLI.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__

# -------------------------------------------------------
# Paths
# -------------------------------------------------------
PKG_DIR      = Path(__file__).parent                       # installed package dir
SCRIPTS_DIR  = PKG_DIR / "scripts"                        # bundled scripts
DEPLOY_DIR   = Path("/opt/zettabrain/src")                 # where scripts live at runtime
NFS_SCRIPT   = SCRIPTS_DIR / "nfs_setup.sh"               # bundled NFS wizard

# Scripts to deploy from package → /opt/zettabrain/src
DEPLOY_SCRIPTS = [
    "03_langchain_rag.py",
    "05_ingest_documents.py",
    "01_chromadb_setup.py",
    "02_embeddings_test.py",
]


# -------------------------------------------------------
# Auto-deploy bundled scripts to /opt/zettabrain/src
# Called on every CLI entry point so scripts are always present
# -------------------------------------------------------
def _deploy_scripts():
    """Copy bundled Python scripts to DEPLOY_DIR if not already present."""
    try:
        DEPLOY_DIR.mkdir(parents=True, exist_ok=True)
    except PermissionError:
        # Non-root user — skip deploy, scripts may already be there
        return

    for script_name in DEPLOY_SCRIPTS:
        src  = SCRIPTS_DIR / script_name
        dest = DEPLOY_DIR  / script_name
        if src.exists() and not dest.exists():
            shutil.copy2(src, dest)
            dest.chmod(0o755)


def _find_script(name: str) -> Path:
    """Find a deployed script, falling back to bundled version."""
    deployed = DEPLOY_DIR / name
    if deployed.exists():
        return deployed
    bundled = SCRIPTS_DIR / name
    if bundled.exists():
        return bundled
    return deployed  # return expected path so error message is helpful


def _find_python() -> str:
    """Return the best available python3 interpreter."""
    venv = os.environ.get("VIRTUAL_ENV")
    if venv:
        p = Path(venv) / "bin" / "python3"
        if p.exists():
            return str(p)
    return sys.executable


def _require(path: Path):
    if not path.exists():
        print(f"ERROR: Script not found: {path}")
        print("Try reinstalling: pipx reinstall zettabrain-rag")
        sys.exit(1)


# -------------------------------------------------------
# Helpers
# -------------------------------------------------------
def _banner():
    print(f"\n╔══════════════════════════════════════════════════════╗")
    print(f"║        ZettaBrain RAG  v{__version__:<29}║")
    print(f"║  Local private AI — your data stays on device       ║")
    print(f"╚══════════════════════════════════════════════════════╝\n")


# -------------------------------------------------------
# zettabrain  (root help)
# -------------------------------------------------------
def main():
    _deploy_scripts()
    _banner()
    parser = argparse.ArgumentParser(
        prog="zettabrain",
        description="ZettaBrain RAG — local private AI over your documents",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  sudo zettabrain-setup    NFS mount wizard + build vector store
  zettabrain-ingest        Ingest documents into the vector store
  zettabrain-chat          Start interactive RAG chat session
  zettabrain-status        Show install info and vector store statistics
        """
    )
    parser.add_argument(
        "--version", action="version",
        version=f"zettabrain-rag {__version__}"
    )
    parser.parse_args()


# -------------------------------------------------------
# zettabrain-setup  (NFS wizard)
# -------------------------------------------------------
def setup_cmd():
    _deploy_scripts()
    _banner()
    _require(NFS_SCRIPT)

    if os.geteuid() != 0:
        print("ERROR: NFS setup requires root privileges.")
        print("Run:   sudo zettabrain-setup\n")
        sys.exit(1)

    NFS_SCRIPT.chmod(0o755)
    result = subprocess.run(["bash", str(NFS_SCRIPT)])
    sys.exit(result.returncode)


# -------------------------------------------------------
# zettabrain-ingest
# -------------------------------------------------------
def ingest_cmd():
    _deploy_scripts()
    _banner()

    script = _find_script("05_ingest_documents.py")
    _require(script)

    parser = argparse.ArgumentParser(
        prog="zettabrain-ingest",
        description="Ingest documents from NFS share into the vector store"
    )
    parser.add_argument("--folder",  default=None,        help="Documents folder (default: /mnt/Rag-data)")
    parser.add_argument("--file",    default=None,        help="Ingest a single file")
    parser.add_argument("--clear",   action="store_true", help="Clear the entire vector store")
    parser.add_argument("--stats",   action="store_true", help="Show vector store statistics")
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

    parser = argparse.ArgumentParser(
        prog="zettabrain-chat",
        description="Start an interactive RAG chat session"
    )
    parser.add_argument("--rebuild", action="store_true", help="Force rebuild vector store before chat")
    parser.add_argument("--debug",   action="store_true", help="Show retrieved chunks on every query")
    parser.add_argument("--model",   default=None,        help="LLM model to use")
    args, _ = parser.parse_known_args()

    cmd = [_find_python(), str(script)]
    if args.rebuild: cmd += ["--rebuild"]
    if args.debug:   cmd += ["--debug"]

    os.chdir(DEPLOY_DIR)
    sys.exit(subprocess.run(cmd).returncode)


# -------------------------------------------------------
# zettabrain-status
# -------------------------------------------------------
def status_cmd():
    _deploy_scripts()
    _banner()

    chroma_path = DEPLOY_DIR / "zettabrain_vectorstore"
    sqlite_db   = chroma_path / "chroma.sqlite3"
    ingest_log  = DEPLOY_DIR / "ingested_files.json"
    nfs_config  = DEPLOY_DIR / "nfs_config.env"

    print(f"Version      : {__version__}")
    print(f"Package dir  : {PKG_DIR}")
    print(f"Scripts dir  : {DEPLOY_DIR}")
    print(f"NFS script   : {NFS_SCRIPT} ({'found' if NFS_SCRIPT.exists() else 'MISSING'})")
    print()

    print("Deployed scripts:")
    for name in DEPLOY_SCRIPTS:
        path   = DEPLOY_DIR / name
        status = "found" if path.exists() else "MISSING"
        print(f"  {name:<35} {status}")
    print()

    if nfs_config.exists():
        print("NFS Config:")
        for line in nfs_config.read_text().splitlines():
            if line and not line.startswith("#"):
                print(f"  {line}")
        print()

    if sqlite_db.exists():
        size_mb = sqlite_db.stat().st_size / (1024 * 1024)
        print(f"Vector store : {chroma_path}")
        print(f"Database     : {size_mb:.1f} MB")
        import json
        if ingest_log.exists():
            data = json.loads(ingest_log.read_text())
            print(f"Tracked files: {len(data)}")
            for fp in sorted(data):
                print(f"  - {Path(fp).name}")
    else:
        print("Vector store : not built yet")
        print("Run: sudo zettabrain-setup")
    print()
