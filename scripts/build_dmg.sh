#!/usr/bin/env bash
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

for arg in "$@"; do
    case "$arg" in
        --app-only) MAKE_DMG=0 ;;
        --skip-metal) BUILD_METAL=0 ;;
        -h|--help)
            echo "Usage: $0 [--app-only] [--skip-metal]"
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
    echo "[build_dmg] generating AppIcon.icns from logo.jpg ..."
    "$SCRIPT_DIR/generate_app_icon.sh" "$REPO_ROOT/logo.jpg"
elif [[ ! -f "$REPO_ROOT/gui/AppIcon.icns" ]]; then
    echo "[build_dmg] warning: no logo.jpg and no gui/AppIcon.icns — app will use default icon"
fi

if [[ "$BUILD_METAL" -eq 1 ]]; then
    echo "[build_dmg] compiling Metal helper ..."
    "$SCRIPT_DIR/build_metal.sh"
fi

if [[ ! -x "$REPO_ROOT/src/metal_nonce_finder" ]]; then
    echo "[build_dmg] error: src/metal_nonce_finder missing."
    exit 1
fi

echo "[build_dmg] compiling SwiftUI app ..."
NATIVE_DIR="$REPO_ROOT/gui/native"
(cd "$NATIVE_DIR" && swift build -c release)
SWIFT_BIN="$NATIVE_DIR/.build/release/BTCCWalletApp"
if [[ ! -x "$SWIFT_BIN" ]]; then
    echo "[build_dmg] error: Swift build failed — $SWIFT_BIN not found"
    exit 1
fi

echo "[build_dmg] assembling ${APP_NAME}.app ..."
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

echo "[build_dmg] built: $APP_BUNDLE"
du -sh "$APP_BUNDLE"

if [[ "$MAKE_DMG" -eq 0 ]]; then
    echo "[build_dmg] done (--app-only)"
    exit 0
fi

echo "[build_dmg] creating DMG ..."
STAGING="$REPO_ROOT/dist/dmg-staging"
ICNS="$REPO_ROOT/gui/AppIcon.icns"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
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

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING"

if [[ -f "$ICNS" ]]; then
    echo "[build_dmg] setting DMG file icon ..."
    if swift "$SCRIPT_DIR/set_file_icon.swift" "$DMG_PATH" "$ICNS"; then
        echo "[build_dmg] DMG file icon applied"
    else
        echo "[build_dmg] warning: could not set DMG file icon"
    fi
fi

echo "[build_dmg] DMG ready: $DMG_PATH"
ls -lh "$DMG_PATH"
echo
echo "Install: open DMG → drag app to Applications → launch from Applications"
