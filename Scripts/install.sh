#!/usr/bin/env bash
set -euo pipefail

# Local installs are branded "Whisper Master Preview" so they coexist with
# the production app without clobbering it.
BUILT_APP_NAME="Whisper Master"        # what bundle.sh always produces
APP_NAME="Whisper Master Preview"      # what install.sh installs locally
PREVIEW_BUNDLE_ID="app.whispermaster.mac.preview"
APP_BIN="WhisperMaster"
BUILT_APP="build/${BUILT_APP_NAME}.app"
SRC_APP="build/${APP_NAME}.app"
DST_APP="/Applications/${APP_NAME}.app"
RELAUNCH="${RELAUNCH:-1}"
REBUILD="${REBUILD:-1}"
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # default ad-hoc for local installs

cd "$(dirname "$0")/.."

if [[ "$REBUILD" == "1" || ! -d "$BUILT_APP" ]]; then
    echo ">> Building .app via bundle.sh"
    bash Scripts/bundle.sh
fi

if [[ ! -d "$BUILT_APP" ]]; then
    echo "error: $BUILT_APP missing after build" >&2
    exit 1
fi

# Rebrand the built app to "Whisper Master Preview" with a distinct bundle ID
# so it can coexist side-by-side with a production install.
echo ">> Rebranding to '${APP_NAME}'"
rm -rf "$SRC_APP"
cp -R "$BUILT_APP" "$SRC_APP"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleName ${APP_NAME}" \
    -c "Set :CFBundleDisplayName ${APP_NAME}" \
    -c "Set :CFBundleIdentifier ${PREVIEW_BUNDLE_ID}" \
    "$SRC_APP/Contents/Info.plist"
# Re-sign after plist edit (ad-hoc is fine for local dev)
codesign -f -s "${SIGN_IDENTITY}" \
    --entitlements Resources/WhisperMaster.entitlements \
    "$SRC_APP" 2>/dev/null || true

if pgrep -x "$APP_BIN" >/dev/null 2>&1; then
    echo ">> Quitting running ${APP_NAME}"
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 0.6
    if pgrep -x "$APP_BIN" >/dev/null 2>&1; then
        echo ">> Force killing leftover process"
        pkill -x "$APP_BIN" || true
        sleep 0.3
    fi
fi

if [[ -d "$DST_APP" ]]; then
    echo ">> Removing existing ${DST_APP}"
    if [[ -w "/Applications" && -w "$DST_APP" ]]; then
        rm -rf "$DST_APP"
    else
        sudo rm -rf "$DST_APP"
    fi
fi

echo ">> Installing to ${DST_APP}"
if [[ -w "/Applications" ]]; then
    cp -R "$SRC_APP" "$DST_APP"
else
    sudo cp -R "$SRC_APP" "$DST_APP"
fi

xattr -dr com.apple.quarantine "$DST_APP" 2>/dev/null || true

if [[ "$RELAUNCH" == "1" ]]; then
    echo ">> Launching ${APP_NAME}"
    open "$DST_APP"
fi

echo "Installed ${DST_APP}"
