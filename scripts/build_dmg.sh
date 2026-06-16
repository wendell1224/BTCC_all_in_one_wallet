#!/bin/bash
# Build BTCC Wallet.app and a drag-to-install .dmg
#
# Native SwiftUI all-in-one: wallet + pool stats + Apple Silicon GPU mining.
# Python is used as a subprocess for mining and wallet crypto.
#
# Requirements: macOS 12+, Xcode Command Line Tools (clang++ + swift)
#
# Usage:
#   ./scripts/build_dmg.sh              # build app + DMG in dist/
#   ./scripts/build_dmg.sh --app-only   # skip DMG
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="BTCC Wallet"
VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
DMG_BASENAME="BTCC-Wallet-v${VERSION}.dmg"
APP_BUNDLE="$REPO_ROOT/dist/${APP_NAME}.app"
DMG_PATH="$REPO_ROOT/dist/${DMG_BASENAME}"
BUILD_METAL=1
MAKE_DMG=1
SET_DMG_ICON=0
FORCE_METAL=0
DMG_TIMEOUT_SECONDS="${DMG_TIMEOUT_SECONDS:-120}"

for arg in "$@"; do
    case "$arg" in
        --app-only) MAKE_DMG=0 ;;
        --skip-metal) BUILD_METAL=0 ;;
        --force-metal) FORCE_METAL=1 ;;
        --set-dmg-icon) SET_DMG_ICON=1 ;;
        -h|--help)
            echo "Usage: $0 [--app-only] [--skip-metal] [--force-metal] [--set-dmg-icon]"
            exit 0
            ;;
    esac
done

if [[ "$(uname)" != "Darwin" ]]; then
    echo "[build_dmg] macOS only"; exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "[build_dmg] error: swift not found. Install Xcode Command Line Tools:"
    echo "    xcode-select --install"
    exit 1
fi

if ! /usr/bin/python3 -c "import hashlib" 2>/dev/null; then
    echo "[build_dmg] warning: /usr/bin/python3 not usable; wallet/mining subprocess needs python3"
fi

echo "[build_dmg] repo: $REPO_ROOT  version: v${VERSION}"

if [[ -f "$REPO_ROOT/logo.jpg" ]]; then
    if [[ ! -f "$REPO_ROOT/gui/AppIcon.icns" || "$REPO_ROOT/logo.jpg" -nt "$REPO_ROOT/gui/AppIcon.icns" ]]; then
        echo "[build_dmg] generating AppIcon.icns from logo.jpg ..."
        "$SCRIPT_DIR/generate_app_icon.sh" "$REPO_ROOT/logo.jpg"
    else
        echo "[build_dmg] AppIcon.icns is up to date"
    fi
elif [[ ! -f "$REPO_ROOT/gui/AppIcon.icns" ]]; then
    echo "[build_dmg] warning: no logo.jpg and no gui/AppIcon.icns — app will use default icon"
fi

if [[ "$BUILD_METAL" -eq 1 ]]; then
    if [[ "$FORCE_METAL" -eq 1 || ! -x "$REPO_ROOT/src/metal_nonce_finder" || "$REPO_ROOT/src/metal_nonce_finder.mm" -nt "$REPO_ROOT/src/metal_nonce_finder" ]]; then
        echo "[build_dmg] compiling Metal helper ..."
        /bin/bash "$SCRIPT_DIR/build_metal.sh"
    else
        echo "[build_dmg] Metal helper is up to date"
    fi
fi

if [[ ! -x "$REPO_ROOT/src/metal_nonce_finder" ]]; then
    echo "[build_dmg] error: src/metal_nonce_finder missing."
    exit 1
fi

echo "[build_dmg] compiling SwiftUI app ..."
NATIVE_DIR="$REPO_ROOT/gui/native"
SWIFT_BUILD_DIR="$REPO_ROOT/dist/swiftpm-build-dmg"
mkdir -p "$REPO_ROOT/dist"
echo "[build_dmg] SwiftPM scratch: $SWIFT_BUILD_DIR"
echo "[build_dmg] note: first release build can take 1-2 minutes with little output"
(cd "$NATIVE_DIR" && swift build -c release --scratch-path "$SWIFT_BUILD_DIR")
SWIFT_BIN="$SWIFT_BUILD_DIR/release/BTCCWalletApp"
if [[ ! -x "$SWIFT_BIN" ]]; then
    echo "[build_dmg] error: Swift build failed — $SWIFT_BIN not found"
    exit 1
fi

echo "[build_dmg] assembling ${APP_NAME}.app ..."
RUNNING_PIDS="$(pgrep -x BTCCWalletApp 2>/dev/null || true)"
if [[ -n "$RUNNING_PIDS" ]]; then
    echo "[build_dmg] stopping running BTCCWalletApp before replacing app bundle ..."
    pkill -x BTCCWalletApp 2>/dev/null || true
    for _ in {1..20}; do
        if ! pgrep -x BTCCWalletApp >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
    if pgrep -x BTCCWalletApp >/dev/null 2>&1; then
        echo "[build_dmg] warning: BTCCWalletApp still running; forcing stop"
        pkill -9 -x BTCCWalletApp 2>/dev/null || true
        sleep 0.5
    fi
fi
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/app/src/wallet"
mkdir -p "$APP_BUNDLE/Contents/Resources/app/scripts"
mkdir -p "$APP_BUNDLE/Contents/Resources/app/tests"

cp "$SWIFT_BIN" "$APP_BUNDLE/Contents/MacOS/BTCCWalletApp"
chmod +x "$APP_BUNDLE/Contents/MacOS/BTCCWalletApp"

cp "$REPO_ROOT/src/"*.py "$APP_BUNDLE/Contents/Resources/app/src/"
cp -R "$REPO_ROOT/src/wallet/"*.py "$APP_BUNDLE/Contents/Resources/app/src/wallet/"
cp "$REPO_ROOT/src/metal_nonce_finder" "$APP_BUNDLE/Contents/Resources/app/src/"
cp "$REPO_ROOT/scripts/build_metal.sh" "$APP_BUNDLE/Contents/Resources/app/scripts/"
chmod +x "$APP_BUNDLE/Contents/Resources/app/scripts/"*.sh
cp "$REPO_ROOT/scripts/test_proxy.sh" "$APP_BUNDLE/Contents/Resources/app/scripts/"
cp "$REPO_ROOT/tests/smoke_metal_nonce_finder.py" "$APP_BUNDLE/Contents/Resources/app/tests/"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>BTCCWalletApp</string>
    <key>CFBundleIdentifier</key><string>org.btc-classic.wallet</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -f "$REPO_ROOT/gui/AppIcon.icns" ]]; then
    cp "$REPO_ROOT/gui/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" \
        "$APP_BUNDLE/Contents/Info.plist"
fi

echo "[build_dmg] clearing extended attributes ..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "[build_dmg] ad-hoc signing app bundle ..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "[build_dmg] built: $APP_BUNDLE"
du -sh "$APP_BUNDLE"
echo "[build_dmg] if Finder blocks open, run: xattr -dr com.apple.quarantine \"$APP_BUNDLE\""

if [[ "$MAKE_DMG" -eq 0 ]]; then
    echo "[build_dmg] done (--app-only)"
    exit 0
fi

echo "[build_dmg] creating DMG ..."
STAGING="$(mktemp -d "$REPO_ROOT/dist/dmg-staging.XXXXXX")"
ICNS="$REPO_ROOT/gui/AppIcon.icns"
cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

rm -f "$DMG_PATH"
echo "[build_dmg] staging app bundle ..."
cp -R "$APP_BUNDLE" "$STAGING/"
xattr -cr "$STAGING/$APP_NAME.app" 2>/dev/null || true
ln -s /Applications "$STAGING/Applications"

if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "$STAGING/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "$STAGING"
        SetFile -a V "$STAGING/.VolumeIcon.icns"
    else
        echo "[build_dmg] warning: SetFile not found; volume icon may be missing"
    fi
fi

run_with_timeout() {
    local seconds="$1"
    shift
    "$@" &
    local pid=$!
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$elapsed" -ge "$seconds" ]]; then
            echo "[build_dmg] error: command timed out after ${seconds}s: $*"
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pid"
}

run_with_timeout "$DMG_TIMEOUT_SECONDS" hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRO \
    "$DMG_PATH"

echo "[build_dmg] cleaning staging ..."
cleanup
trap - EXIT

if [[ "$SET_DMG_ICON" -eq 1 && -f "$ICNS" ]]; then
    echo "[build_dmg] setting DMG file icon ..."
    if swift "$SCRIPT_DIR/set_file_icon.swift" "$DMG_PATH" "$ICNS"; then
        echo "[build_dmg] DMG file icon applied"
    else
        echo "[build_dmg] warning: could not set DMG file icon"
    fi
else
    echo "[build_dmg] skipping DMG file icon step"
fi

echo "[build_dmg] DMG ready: $DMG_PATH"
ls -lh "$DMG_PATH"
echo
echo "Install: open DMG → drag app to Applications → launch from Applications"
