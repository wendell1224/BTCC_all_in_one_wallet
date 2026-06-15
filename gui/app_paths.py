"""Resolve application paths for dev checkout vs .app bundle."""
from __future__ import annotations

import os
import socket
import subprocess
import sys
from pathlib import Path


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "BTCCAppleGPUMiner"
SETTINGS_FILE = APP_SUPPORT / "settings.json"
DEFAULT_POOL = "stratum+tcp://pool.btc-classic.org:63101"


def repo_root() -> Path:
    env = os.environ.get("BTCC_MINER_ROOT")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent


def src_dir() -> Path:
    return repo_root() / "src"


def scripts_dir() -> Path:
    return repo_root() / "scripts"


def gpu_binary() -> Path:
    return src_dir() / "metal_nonce_finder"


def python_exe() -> str:
    return sys.executable


def default_worker() -> str:
    try:
        return socket.gethostname().split(".")[0] or "worker"
    except Exception:
        return "worker"


def ensure_app_support() -> Path:
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    return APP_SUPPORT


def gpu_binary_ready() -> bool:
    p = gpu_binary()
    return p.is_file() and os.access(p, os.X_OK)


def build_metal_helper(log_cb=None) -> tuple[bool, str]:
    """Compile metal_nonce_finder. Returns (ok, message)."""
    build_sh = scripts_dir() / "build_metal.sh"
    if not build_sh.is_file():
        return False, f"build script not found: {build_sh}"
    try:
        proc = subprocess.run(
            ["/bin/bash", str(build_sh)],
            cwd=str(repo_root()),
            capture_output=True,
            text=True,
            timeout=120,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        if log_cb:
            for line in out.splitlines():
                log_cb(line)
        if proc.returncode != 0:
            return False, f"build failed (exit {proc.returncode})"
        if not gpu_binary_ready():
            return False, "build finished but binary missing"
        return True, f"built {gpu_binary()}"
    except subprocess.TimeoutExpired:
        return False, "build timed out"
    except Exception as e:
        return False, str(e)
