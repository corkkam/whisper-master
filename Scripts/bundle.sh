#!/usr/bin/env bash
set -euo pipefail

# Builds the distributable .app via the Xcode project (generated from
# project.yml by XcodeGen) and stages it at build/Whisper Master.app, the path
# that make-dmg.sh and install.sh consume.

cd "$(dirname "$0")/.."

# Release channel (stable|beta) → CH_APP_NAME, CH_BUNDLE_ID, CH_SU_FEED_URL.
source "$(dirname "$0")/channel.sh"

APP_NAME="$CH_APP_NAME"            # distribution .app filename (with space)
SCHEME="WhisperMaster"             # Xcode scheme / product name (no space)
CONFIG="${CONFIG:-Release}"        # Release | Debug
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}" # keychain identity; pass "-" for ad-hoc
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-7MFYAGK3VV}" # Developer ID team (manual signing requires it)

# Load local config (git-ignored). Supplies POSTHOG_API_KEY for the analytics
# key baked into Info.plist below; CI passes the same var from a secret instead.
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi

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

# Opt-in local diagnostics build: DIAGNOSTICS=1 compiles the on-disk session
# tracer (Sources/WhisperMaster/Diagnostics). Stays a *Release* (optimized) build
# so latency/RTF numbers are real — only the compile flag flips. CI never sets it,
# so the shipped build can't compile the tracer and can't write anyone's audio.
BUILD_FLAGS=()
if [[ "${DIAGNOSTICS:-0}" == "1" ]]; then
    echo ">> DIAGNOSTICS=1 — compiling local session tracer into this build"
    BUILD_FLAGS+=(SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DIAGNOSTICS')
fi

DERIVED="build/DerivedData"
BUILD_LOG="build/xcodebuild-$CONFIG.log"
mkdir -p build
echo ">> Building $SCHEME ($CONFIG) with xcodebuild"
# Don't swallow xcodebuild's output: keep a full log and surface
# errors/warnings to the console (and CI logs) so a compile failure is
# actually diagnosable. `PIPESTATUS[0]` preserves xcodebuild's real exit code
# through the filter pipe.
set +e
xcodebuild \
    -project WhisperMaster.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    POSTHOG_API_KEY="${POSTHOG_API_KEY:-}" \
    ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} \
    ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} \
    clean build 2>&1 | tee "$BUILD_LOG" | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"
# PIPESTATUS[0] is xcodebuild's real exit code. (Do NOT append `|| true` to the
# pipeline — that runs a new command and resets PIPESTATUS, masking failures.)
xc_status=${PIPESTATUS[0]}
set -e
if [[ "$xc_status" -ne 0 ]]; then
    echo "error: xcodebuild failed (exit $xc_status). Full log: $BUILD_LOG" >&2
    exit 1
fi

PRODUCT="$DERIVED/Build/Products/$CONFIG/$SCHEME.app"
APP_DIR="build/${APP_NAME}.app"

if [[ ! -d "$PRODUCT" ]]; then
    echo "error: build product not found at $PRODUCT" >&2
    exit 1
fi

# Sanity-check the product is a complete app before we ever stage/ship it —
# the executable and the embedded Sparkle framework must be present. Guards
# against publishing a partial bundle if a build half-succeeds.
if [[ ! -x "$PRODUCT/Contents/MacOS/$SCHEME" || ! -d "$PRODUCT/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "error: build product at $PRODUCT looks incomplete (missing executable or Sparkle.framework). Full log: $BUILD_LOG" >&2
    exit 1
fi

echo ">> Staging $APP_DIR"
rm -rf "$APP_DIR"
cp -R "$PRODUCT" "$APP_DIR"

# Beta channel: re-badge the staged bundle so it installs SIDE-BY-SIDE with the
# stable app (distinct bundle id → its own TCC/Sparkle/settings) and polls the
# beta appcast. Done on the staged copy only — project.yml/Info.plist are
# untouched. The edited Info.plist invalidates the seal, so it is re-signed by
# the signing step below (DevID) or the ad-hoc fallback further down. The
# executable name is intentionally left as WhisperMaster: side-by-side works via
# the distinct bundle id + ".app" folder name; the process name doesn't matter
# for a distributed build. See channel.sh.
if [[ "$CHANNEL" == "beta" ]]; then
    INFO="$APP_DIR/Contents/Info.plist"
    PLB=/usr/libexec/PlistBuddy
    echo ">> Re-badging for beta channel: id=$CH_BUNDLE_ID name=\"$CH_APP_NAME\""
    $PLB -c "Set :CFBundleIdentifier $CH_BUNDLE_ID" "$INFO"
    $PLB -c "Set :CFBundleName $CH_APP_NAME" "$INFO"
    $PLB -c "Set :CFBundleDisplayName $CH_APP_NAME" "$INFO"
    $PLB -c "Set :SUFeedURL $CH_SU_FEED_URL" "$INFO"
fi

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

# Ad-hoc + beta: the DevID block above was skipped, but the beta re-badge edited
# Info.plist and invalidated the ad-hoc seal — re-sign the top level so the
# staged bundle stays launchable (local `CHANNEL=beta SIGN_IDENTITY=- bundle.sh`
# smoke checks). Real beta releases go through release.sh with a Developer ID.
if [[ "$SIGN_IDENTITY" == "-" && "$CHANNEL" == "beta" ]]; then
    echo ">> Re-signing beta bundle ad-hoc (Info.plist was edited)"
    codesign -f -s - --entitlements Resources/WhisperMaster.entitlements "$APP_DIR"
fi

echo "Built $APP_DIR (signed: ${SIGN_IDENTITY})"
echo "Run with: open \"$APP_DIR\""
echo "Notarize with: bash Scripts/notarize.sh \"$APP_DIR\""
