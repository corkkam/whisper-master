#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Release channel (stable|beta|dev) → CH_APP_NAME. Sourced for the same reason
# bundle.sh does it: bundle.sh stages a channel-named .app ("Whisper Master
# Dev.app"), so an installer with the stable name hardcoded could only ever find
# a stable build — it failed with "missing after build" on any other channel.
source "$(dirname "$0")/channel.sh"

APP_NAME="$CH_APP_NAME"
SRC_APP="build/${APP_NAME}.app"
DST_APP="/Applications/${APP_NAME}.app"
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
if pkill -f "^${DST_APP}/Contents/MacOS/" 2>/dev/null; then
    echo ">> Force killed a leftover process running from ${DST_APP}"
    sleep 0.3
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
