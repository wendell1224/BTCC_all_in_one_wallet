#!/usr/bin/env bash
# Launch the BTCC Wallet Electron app from a dev checkout.
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

export BTCC_WALLET_DEV_ROOT="$REPO_ROOT"
exec npm run start:electron
