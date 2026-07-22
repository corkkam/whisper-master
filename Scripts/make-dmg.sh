#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Release channel (stable|beta) → CH_APP_NAME. Beta wraps "Whisper Master Beta.app".
source "$(dirname "$0")/channel.sh"

APP_NAME="$CH_APP_NAME"
APP_PATH="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}.dmg"
VOLUME_NAME="$CH_APP_NAME"
REBUILD="${REBUILD:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}" # pass "-" to skip DMG signing

if [[ "$REBUILD" == "1" || ! -d "$APP_PATH" ]]; then
    echo ">> Building .app via bundle.sh"
    bash Scripts/bundle.sh
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH does not exist after build" >&2
    exit 1
fi

# Notarize + staple the app first so the copy inside the DMG carries the ticket.
# No-op if NOTARY_* credentials aren't set.
echo ">> Notarizing the app"
bash Scripts/notarize.sh "$APP_PATH"

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

# Code-sign the DMG BEFORE notarizing: Gatekeeper's disk-image assessment needs
# a Developer ID signature for the stapled notarization ticket to validate
# against (a notarized-but-unsigned DMG is still rejected with "no usable
# signature"). Signing must precede notarization since it changes the bytes.
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo ">> Code-signing the DMG"
    codesign -s "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

# Notarize + staple the DMG itself so Gatekeeper is satisfied at mount time too.
echo ">> Notarizing the DMG"
bash Scripts/notarize.sh "$DMG_PATH"

echo "Built $DMG_PATH"
ls -lh "$DMG_PATH"
