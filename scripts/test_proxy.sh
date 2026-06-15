#!/usr/bin/env bash
# Quick proxy diagnostics for stratum mining.
#
# Usage:
#   scripts/test_proxy.sh [proxy_url] [pool_host] [pool_port]
#
# Examples:
#   scripts/test_proxy.sh socks5://127.0.0.1:7890
#   scripts/test_proxy.sh http://127.0.0.1:7890
#   scripts/test_proxy.sh socks5://127.0.0.1:7891 pool.btc-classic.org 63101
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROXY_URL="${1:-socks5://127.0.0.1:7890}"
POOL_HOST="${2:-pool.btc-classic.org}"
POOL_PORT="${3:-63101}"

echo "[test] proxy : $PROXY_URL"
echo "[test] target: $POOL_HOST:$POOL_PORT"
echo

python3 - "$PROXY_URL" "$POOL_HOST" "$POOL_PORT" <<'PY'
import json
import sys
import time

sys.path.insert(0, "src")
from stratum_miner import parse_proxy_url, _connect_via_proxy

proxy_url, host, port_s = sys.argv[1:4]
port = int(port_s)
cfg = parse_proxy_url(proxy_url)

print(f"[test] parsed proxy: {cfg.scheme}://{cfg.host}:{cfg.port}")
print(f"[test] opening tunnel ...")
t0 = time.time()
sock = _connect_via_proxy(cfg, host, port, timeout=15.0)
print(f"[test] tunnel up in {time.time() - t0:.2f}s")

req = json.dumps({"id": 1, "method": "mining.subscribe", "params": ["proxy-test/0.1"]}) + "\n"
sock.settimeout(10.0)
sock.sendall(req.encode("utf-8"))
print(f"[test] sent mining.subscribe, waiting for reply ...")

try:
    data = sock.recv(65536)
except TimeoutError:
    print("[test] FAIL: no data within 10s — proxy may not reach the pool, "
          "or Clash routed this host to DIRECT/REJECT")
    raise SystemExit(1)

if not data:
    print("[test] FAIL: pool/proxy closed immediately (0 bytes) — "
          "same silent-drop symptom as direct connect")
    raise SystemExit(1)

line = data.split(b"\n", 1)[0]
print(f"[test] OK: got {len(data)} bytes")
print(f"[test] first line: {line[:200]!r}")

try:
    msg = json.loads(line.decode("utf-8"))
except Exception as e:
    print(f"[test] WARN: reply is not JSON ({e}) — wrong port/protocol? "
          f"Clash SOCKS is often 7891, mixed HTTP is 7890")
    raise SystemExit(1)

if msg.get("result"):
    print("[test] PASS: mining.subscribe succeeded through proxy")
else:
    print(f"[test] WARN: JSON received but no result: {msg!r}")
    raise SystemExit(1)
PY
