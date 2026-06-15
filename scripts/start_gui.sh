#!/usr/bin/env bash
# Launch the BTCC Wallet SwiftUI app from a dev checkout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NATIVE="$REPO_ROOT/gui/native"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "macOS only"; exit 1
fi

if [[ ! -x "$REPO_ROOT/src/metal_nonce_finder" ]]; then
    echo "[gui] building metal_nonce_finder ..."
    "$SCRIPT_DIR/build_metal.sh"
fi

RES="$NATIVE/.build/Resources"
mkdir -p "$RES"
rm -rf "$RES/app"
ln -sf "$REPO_ROOT" "$RES/app"

export BTCC_WALLET_DEV_ROOT="$REPO_ROOT"
export BTCC_MINER_DEV_ROOT="$REPO_ROOT"
cd "$NATIVE"

if [[ ! -x "$NATIVE/.build/release/BTCCWalletApp" ]]; then
    echo "[gui] compiling SwiftUI app (first run) ..."
    swift build -c release
fi

exec "$NATIVE/.build/release/BTCCWalletApp"
