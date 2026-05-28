#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Whisper Master"
DISPLAY_NAME="Whisper Master"
BIN="WhisperMasterPrototype"
APP_BIN="WhisperMaster"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-whisper master}"

cd "$(dirname "$0")/.."

swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="build/${APP_NAME}.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/$BIN" "$APP_DIR/Contents/MacOS/$APP_BIN"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

for bundle in "$BIN_PATH"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

echo ">> Signing ${DISPLAY_NAME} with identity: ${SIGN_IDENTITY}"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

echo "Built $APP_DIR"
echo "Run with: open $APP_DIR"
