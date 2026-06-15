#!/usr/bin/env bash
# Build a versioned DMG and publish to GitHub Releases.
#
# Prerequisites:
#   brew install gh
#   gh auth login
#
# Usage:
#   ./scripts/release.sh              # release VERSION from ./VERSION (tag v1.0.0)
#   ./scripts/release.sh --build-only # build DMG only, do not publish
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=1 ;;
        -h|--help)
            echo "Usage: $0 [--build-only]"
            echo "  Version is read from VERSION file (currently v$(tr -d '[:space:]' < "$REPO_ROOT/VERSION"))."
            echo "  Release notes: docs/releases/vX.Y.Z.md"
            exit 0
            ;;
        *)
            echo "[release] unknown arg: $arg (try --build-only)"
            exit 2
            ;;
    esac
done

VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
TAG="v${VERSION}"
NOTES="$REPO_ROOT/docs/releases/${TAG}.md"
DMG="$REPO_ROOT/dist/BTCC-Wallet-v${VERSION}.dmg"

echo "[release] version: ${VERSION}  tag: ${TAG}"

if [[ ! -f "$NOTES" ]]; then
    echo "[release] error: release notes not found: $NOTES"
    echo "  Create that file before publishing."
    exit 1
fi

echo "[release] building DMG ..."
"$SCRIPT_DIR/build_dmg.sh"

if [[ ! -f "$DMG" ]]; then
    echo "[release] error: expected DMG missing: $DMG"
    exit 1
fi

echo "[release] built: $DMG"
ls -lh "$DMG"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
    echo "[release] done (--build-only)"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[release] error: gh CLI not found."
    echo "  brew install gh && gh auth login"
    exit 1
fi

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
    echo "[release] warning: git working tree has uncommitted changes"
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "[release] release ${TAG} exists — uploading/replacing DMG asset ..."
    gh release upload "$TAG" "$DMG" --clobber
else
    echo "[release] creating GitHub release ${TAG} ..."
    gh release create "$TAG" "$DMG" \
        --title "BTCC Wallet ${TAG}" \
        --notes-file "$NOTES"
fi

echo "[release] done: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/${TAG}"
