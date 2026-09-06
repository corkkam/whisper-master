#!/usr/bin/env bash
set -euo pipefail

# Uploads a demo video (and optional poster) for a release note, then prints the
# URLs to paste into whats-new.json.
#
#   bash Scripts/upload-whats-new-media.sh 1.1.0 demo.mp4 [poster.jpg]
#
# RUN THIS BY HAND, NOT IN CI. The video is recorded and uploaded out of band,
# deliberately decoupled from the release: the app streams it from R2 rather
# than bundling it, so a demo can be published — or replaced — without cutting a
# release. CI has no video to upload and never calls this.
#
# Media is NOT committed to the repo: a demo video is tens of megabytes and
# would bloat every clone forever.

cd "$(dirname "$0")/.."

# The host the shipped app actually reads (Auth/BetaAccess.swift).
#
# ⚠️ Deliberately NOT $R2_PUBLIC_BASE_URL. That secret is STALE — it still names
# a retired r2.dev host — so URLs built from it would 404 for every user. See
# CLAUDE.md → "The public R2 host is baked into shipped bundles in three
# places". Change this only alongside those.
PUBLIC_BASE_URL="${WHATS_NEW_PUBLIC_BASE_URL:-https://dl.corkkam.com}"
PREFIX="whats-new"

usage() {
    echo "usage: bash Scripts/upload-whats-new-media.sh <version> <video> [poster]" >&2
    echo "   e.g. bash Scripts/upload-whats-new-media.sh 1.1.0 demo.mp4 poster.jpg" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage
VERSION="$1"
VIDEO="$2"
POSTER="${3:-}"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z.-]+)?$ ]] \
    || { echo "error: '$VERSION' is not a well-formed version" >&2; exit 1; }
[[ -f "$VIDEO" ]] || { echo "error: video not found: $VIDEO" >&2; exit 1; }
[[ -z "$POSTER" || -f "$POSTER" ]] || { echo "error: poster not found: $POSTER" >&2; exit 1; }

VIDEO_EXT="${VIDEO##*.}"
VIDEO_KEY="$PREFIX/$VERSION.$VIDEO_EXT"

# --- Load R2 credentials (same convention as release.sh) ---
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi
: "${R2_ACCESS_KEY_ID:?missing in .env}"
: "${R2_SECRET_ACCESS_KEY:?missing in .env}"
: "${R2_BUCKET:?missing in .env}"
: "${R2_ENDPOINT:?missing in .env}"

command -v rclone >/dev/null || { echo "error: rclone not installed (brew install rclone)" >&2; exit 1; }

export RCLONE_S3_PROVIDER=Cloudflare
export RCLONE_S3_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_S3_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_S3_ENDPOINT="$R2_ENDPOINT"
export RCLONE_S3_REGION=auto

echo ">> Uploading $VIDEO → $VIDEO_KEY"
rclone copyto "$VIDEO" ":s3:$R2_BUCKET/$VIDEO_KEY" --s3-no-check-bucket --progress

POSTER_URL=""
if [[ -n "$POSTER" ]]; then
    POSTER_KEY="$PREFIX/$VERSION.${POSTER##*.}"
    echo ">> Uploading $POSTER → $POSTER_KEY"
    rclone copyto "$POSTER" ":s3:$R2_BUCKET/$POSTER_KEY" --s3-no-check-bucket --progress
    POSTER_URL="${PUBLIC_BASE_URL%/}/$POSTER_KEY"
fi

echo
echo "Paste into the release entry in whats-new.json:"
echo
echo "      \"videoURL\": \"${PUBLIC_BASE_URL%/}/$VIDEO_KEY\","
if [[ -n "$POSTER_URL" ]]; then
    echo "      \"posterURL\": \"$POSTER_URL\","
fi
echo
echo "Then: bash Scripts/publish-whats-new.sh --check && git commit whats-new.json"
