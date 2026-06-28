#!/usr/bin/env bash
set -euo pipefail

# Builds the distributable .app via the Xcode project (generated from
# project.yml by XcodeGen) and stages it at build/Whisper Master.app, the path
# that make-dmg.sh and install.sh consume.

APP_NAME="Whisper Master"          # distribution .app filename (with space)
SCHEME="WhisperMaster"             # Xcode scheme / product name (no space)
CONFIG="${CONFIG:-Release}"        # Release | Debug
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}" # keychain identity; pass "-" for ad-hoc
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-7MFYAGK3VV}" # Developer ID team (manual signing requires it)

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not installed — run: brew install xcodegen" >&2
    exit 1
fi

echo ">> Generating Xcode project from project.yml"
xcodegen generate >/dev/null

# A real (non-ad-hoc) identity gets a secure timestamp, which Apple notarization
# requires; ad-hoc ("-") signing can't be timestamped, so skip the flag there.
SIGN_FLAGS=()
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_FLAGS+=(OTHER_CODE_SIGN_FLAGS="--timestamp" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

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
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} \
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

# xcodebuild re-signs the outer Sparkle.framework but NOT the code nested inside
# it (Updater.app, Autoupdate, the XPC services), so they keep Sparkle's ad-hoc
# signature with no secure timestamp — which makes Apple notarization fail. When
# signing for real, re-sign those inside-out with our Developer ID + hardened
# runtime + timestamp, preserving the XPC services' own entitlements, then
# re-seal the framework and the whole app.
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    FW="$APP_DIR/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$FW" ]]; then
        echo ">> Re-signing nested Sparkle helpers with $SIGN_IDENTITY"
        V="$FW/Versions/B"
        for xpc in "$V/XPCServices/Downloader.xpc" "$V/XPCServices/Installer.xpc"; do
            [[ -e "$xpc" ]] && codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
                --preserve-metadata=entitlements "$xpc"
        done
        codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp "$V/Updater.app"
        codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp "$V/Autoupdate"
        codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp "$FW"
    fi
    echo ">> Re-sealing the app bundle"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
        --entitlements Resources/WhisperMaster.entitlements "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"
fi

echo "Built $APP_DIR (signed: ${SIGN_IDENTITY})"
echo "Run with: open \"$APP_DIR\""
echo "Notarize with: bash Scripts/notarize.sh \"$APP_DIR\""
