#!/usr/bin/env bash
set -euo pipefail

# Builds the distributable .app via the Xcode project (generated from
# project.yml by XcodeGen) and stages it at build/Whisper Master.app, the path
# that make-dmg.sh and install.sh consume.

APP_NAME="Whisper Master"          # distribution .app filename (with space)
SCHEME="WhisperMaster"             # Xcode scheme / product name (no space)
CONFIG="${CONFIG:-Release}"        # Release | Debug
SIGN_IDENTITY="${SIGN_IDENTITY:-whisper master}" # keychain identity; pass "-" for ad-hoc

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not installed — run: brew install xcodegen" >&2
    exit 1
fi

echo ">> Generating Xcode project from project.yml"
xcodegen generate >/dev/null

DERIVED="build/DerivedData"
echo ">> Building $SCHEME ($CONFIG) with xcodebuild"
xcodebuild \
    -project WhisperMaster.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    clean build >/dev/null

PRODUCT="$DERIVED/Build/Products/$CONFIG/$SCHEME.app"
APP_DIR="build/${APP_NAME}.app"

if [[ ! -d "$PRODUCT" ]]; then
    echo "error: build product not found at $PRODUCT" >&2
    exit 1
fi

echo ">> Staging $APP_DIR"
rm -rf "$APP_DIR"
cp -R "$PRODUCT" "$APP_DIR"

echo "Built $APP_DIR (signed: ${SIGN_IDENTITY})"
echo "Run with: open \"$APP_DIR\""
