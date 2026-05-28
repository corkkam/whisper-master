#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Whisper Master"
APP_PATH="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}.dmg"
VOLUME_NAME="Whisper Master"
REBUILD="${REBUILD:-1}"

if [[ "$REBUILD" == "1" || ! -d "$APP_PATH" ]]; then
    echo ">> Building .app via bundle.sh"
    bash Scripts/bundle.sh
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH does not exist after build" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo ">> Staging DMG contents at $STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil detach "/Volumes/${VOLUME_NAME}" -force >/dev/null 2>&1 || true

rm -f "$DMG_PATH"

echo ">> Creating DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

echo "Built $DMG_PATH"
ls -lh "$DMG_PATH"
