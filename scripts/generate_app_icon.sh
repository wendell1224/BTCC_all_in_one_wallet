#!/usr/bin/env bash
# Generate gui/AppIcon.icns from logo.jpg (or any square PNG/JPEG).
#
# Usage:
#   ./scripts/generate_app_icon.sh
#   ./scripts/generate_app_icon.sh path/to/logo.png
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${1:-$REPO_ROOT/logo.jpg}"
OUT="$REPO_ROOT/gui/AppIcon.icns"
ICONSET="$REPO_ROOT/gui/AppIcon.iconset"
MASTER="$(mktemp -t btcc-icon).png"

cleanup() { rm -f "$MASTER"; }
trap cleanup EXIT

if [[ ! -f "$SRC" ]]; then
    echo "[icon] error: source image not found: $SRC"
    exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
    echo "[icon] error: iconutil not found (macOS only)"
    exit 1
fi

echo "[icon] source: $SRC"
# iconutil requires PNG members in the iconset
sips -s format png "$SRC" --out "$MASTER" >/dev/null

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

gen() {
    local size="$1"
    local name="$2"
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
}

gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "[icon] wrote: $OUT"
ls -lh "$OUT"
