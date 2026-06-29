#!/usr/bin/env bash
# Build the Electron BTCC Wallet app.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

if [[ ! -d node_modules ]]; then
    npm install --cache .npm-cache
fi

if [[ "$(uname)" == "Darwin" && ! -x "$REPO_ROOT/src/metal_nonce_finder" ]]; then
    echo "[electron] building metal_nonce_finder ..."
    "$SCRIPT_DIR/build_metal.sh"
fi

if [[ "${1:-}" == "--dir" ]]; then
    npm run build:electron:dir
else
    npm run build:electron
fi
