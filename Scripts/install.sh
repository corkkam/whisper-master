#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Whisper Master"
APP_BIN="WhisperMaster"
SRC_APP="build/${APP_NAME}.app"
DST_APP="/Applications/${APP_NAME}.app"
RELAUNCH="${RELAUNCH:-1}"
REBUILD="${REBUILD:-1}"

cd "$(dirname "$0")/.."

if [[ "$REBUILD" == "1" || ! -d "$SRC_APP" ]]; then
    echo ">> Building .app via bundle.sh"
    bash Scripts/bundle.sh
fi

if [[ ! -d "$SRC_APP" ]]; then
    echo "error: $SRC_APP missing after build" >&2
    exit 1
fi

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
