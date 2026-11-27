#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Release channel (stable|beta|dev) → CH_APP_NAME. Sourced for the same reason
# bundle.sh does it: bundle.sh stages a channel-named .app ("Typing.sucks
# Dev.app"), so an installer with the stable name hardcoded could only ever find
# a stable build — it failed with "missing after build" on any other channel.
source "$(dirname "$0")/channel.sh"

APP_NAME="$CH_APP_NAME"
SRC_APP="build/${APP_NAME}.app"
DST_APP="/Applications/${APP_NAME}.app"
# The product was "Whisper Master" until 2026-11-27. The bundle id did not change, so
# a Mac that installed an older build still has the old .app next to the new one, and
# macOS would list two copies of one app. It is removed below.
LEGACY_APP="/Applications/${CH_LEGACY_APP_NAME}.app"
RELAUNCH="${RELAUNCH:-1}"
REBUILD="${REBUILD:-1}"

if [[ "$REBUILD" == "1" || ! -d "$SRC_APP" ]]; then
    echo ">> Building .app via bundle.sh"
    bash Scripts/bundle.sh
fi

if [[ ! -d "$SRC_APP" ]]; then
    echo "error: $SRC_APP missing after build" >&2
    exit 1
fi

# Quit any running instance of THIS channel's app, whoever built it.
#
# ⚠️ The executable name is not a reliable key. bundle.sh leaves it
# "WhisperMaster" on every channel, but an Xcode Run of the dev scheme produces
# "WhisperMasterDev" — so `pgrep -x WhisperMaster` silently matched nothing, the
# old process kept running while this script deleted and replaced its bundle
# underneath it, and `open` then just re-activated that stale process. The app
# went on serving resources from the build we had already removed, which reads as
# "the new logo didn't apply" when in fact the new logo was never loaded.
#
# So: ask by bundle id (channel-specific, build-system agnostic), then fall back
# to killing whatever is executing out of the install path.
echo ">> Quitting any running ${APP_NAME}"
osascript -e "tell application id \"${CH_BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.6
for old in "$DST_APP" "$LEGACY_APP"; do
    if pkill -f "^${old}/Contents/MacOS/" 2>/dev/null; then
        echo ">> Force killed a leftover process running from ${old}"
        sleep 0.3
    fi
done

remove_app() {
    if [[ -w "/Applications" && -w "$1" ]]; then
        rm -rf "$1"
    else
        sudo rm -rf "$1"
    fi
}

if [[ -d "$DST_APP" ]]; then
    echo ">> Removing existing ${DST_APP}"
    remove_app "$DST_APP"
fi

# Remove the pre-rename copy, but only when it really is this app. The bundle id
# check keeps an unrelated app that happens to be called "Whisper Master" safe.
if [[ -d "$LEGACY_APP" ]]; then
    legacy_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$LEGACY_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$legacy_id" == "$CH_BUNDLE_ID" ]]; then
        echo ">> Removing the pre-rename copy ${LEGACY_APP}"
        remove_app "$LEGACY_APP"
    else
        echo ">> Leaving ${LEGACY_APP} alone (bundle id '${legacy_id}', not ${CH_BUNDLE_ID})"
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
