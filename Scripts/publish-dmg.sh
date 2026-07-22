#!/usr/bin/env bash
set -euo pipefail

# Publishes a notarized, shareable .dmg to R2 so there's always an up-to-date
# direct-download link (no Sparkle, no App Store — just "here, grab this").
#
# Assumes the signed app already exists at build/Whisper Master.app (i.e. run
# AFTER release.sh / bundle.sh). It:
#   1. builds + notarizes + staples the DMG via make-dmg.sh (REBUILD=0 reuses the
#      app release.sh already built + stapled; notarize.sh skips the app since
#      it's already stapled, so only the DMG itself pays a notary round-trip),
#   2. uploads it to the R2 bucket under TWO keys:
#        - WhisperMaster.dmg            → the STABLE share link (always newest)
#        - WhisperMaster-<version>.dmg  → a versioned archive copy
#
# Credentials: R2_* + NOTARY_* come from .env locally or CI env vars, same as
# release.sh / notarize.sh.

cd "$(dirname "$0")/.."

# Release channel (stable|beta) → CH_APP_NAME + CH_DMG_STABLE_NAME. Beta uploads
# to WhisperMaster-beta.dmg (the gated /download beta link), never the stable
# WhisperMaster.dmg. See channel.sh.
source "$(dirname "$0")/channel.sh"

APP_NAME="$CH_APP_NAME"
APP_PATH="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}.dmg"
STABLE_NAME="$CH_DMG_STABLE_NAME"

# --- Load R2 credentials (CI passes these as env vars) ---
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi
: "${R2_ACCESS_KEY_ID:?missing in .env}"
: "${R2_SECRET_ACCESS_KEY:?missing in .env}"
: "${R2_BUCKET:?missing in .env}"
: "${R2_ENDPOINT:?missing in .env}"
: "${R2_PUBLIC_BASE_URL:?missing in .env}"

command -v rclone >/dev/null || { echo "error: rclone not installed (brew install rclone)" >&2; exit 1; }

[[ -d "$APP_PATH" ]] || { echo "error: $APP_PATH missing — run bundle.sh/release.sh first" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
VERSIONED_NAME="WhisperMaster-$VERSION.dmg"

# --- Build + notarize + staple the DMG (reuse the already-built app) ---
echo ">> Building shareable DMG for $VERSION"
REBUILD=0 bash Scripts/make-dmg.sh

# --- Upload to R2 under both the stable and versioned names ---
echo ">> Uploading DMG to R2 bucket: $R2_BUCKET"
export RCLONE_S3_PROVIDER=Cloudflare
export RCLONE_S3_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_S3_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_S3_ENDPOINT="$R2_ENDPOINT"
export RCLONE_S3_REGION=auto

rclone copyto "$DMG_PATH" ":s3:$R2_BUCKET/$VERSIONED_NAME" --s3-no-check-bucket
rclone copyto "$DMG_PATH" ":s3:$R2_BUCKET/$STABLE_NAME"    --s3-no-check-bucket

echo ""
echo "Published DMG $VERSION:"
echo "  share (stable): ${R2_PUBLIC_BASE_URL%/}/$STABLE_NAME"
echo "  versioned:      ${R2_PUBLIC_BASE_URL%/}/$VERSIONED_NAME"
