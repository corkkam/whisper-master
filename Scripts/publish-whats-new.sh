#!/usr/bin/env bash
set -euo pipefail

# Validates whats-new.json and uploads it to the R2 bucket root, next to the
# Sparkle appcasts, as `whats-new.json`. The app fetches it after a Sparkle
# update relaunches it on a newer version.
#
#   bash Scripts/publish-whats-new.sh --check   # validate only, no credentials
#   bash Scripts/publish-whats-new.sh           # validate + upload
#
# ONE MANIFEST SERVES ALL THREE CHANNELS. Unlike appcast.xml / appcast-beta.xml
# / appcast-dev.xml, this file is not per-channel: a beta and a stable build at
# the same version show the same note. So it uploads to the same key whichever
# channel is releasing, and it never touches an appcast or a DMG.
#
# Safe to run on every release — re-uploading an unchanged manifest is a no-op
# for users (the app re-fetches each launch that clears the version gate).

cd "$(dirname "$0")/.."

MANIFEST="whats-new.json"
REMOTE_NAME="whats-new.json"
CHECK_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --check|--dry-run) CHECK_ONLY=1 ;;
        *) echo "error: unknown argument '$arg' (expected --check)" >&2; exit 2 ;;
    esac
done

[[ -f "$MANIFEST" ]] || { echo "error: $MANIFEST not found" >&2; exit 1; }

# --- Validate (always, including right before an upload) ---
# A malformed manifest reaching R2 is invisible in the field: the app degrades
# to showing nothing, so nobody reports it. This is the only gate.
echo ">> Validating $MANIFEST"
python3 Scripts/whats-new-validate.py "$MANIFEST"

# The published copy drops the `_README` authoring block.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
python3 Scripts/whats-new-validate.py --print "$MANIFEST" > "$STAGE/$REMOTE_NAME"

if [[ "$CHECK_ONLY" == "1" ]]; then
    echo ">> --check: validated and rendered, not uploading"
    echo "   would upload $(wc -c < "$STAGE/$REMOTE_NAME" | tr -d ' ') bytes to <bucket>/$REMOTE_NAME"
    exit 0
fi

# --- Load R2 credentials (same convention as release.sh) ---
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi
: "${R2_ACCESS_KEY_ID:?missing in .env}"
: "${R2_SECRET_ACCESS_KEY:?missing in .env}"
: "${R2_BUCKET:?missing in .env}"
: "${R2_ENDPOINT:?missing in .env}"

command -v rclone >/dev/null || { echo "error: rclone not installed (brew install rclone)" >&2; exit 1; }

echo ">> Uploading $REMOTE_NAME to R2 bucket: $R2_BUCKET"
export RCLONE_S3_PROVIDER=Cloudflare
export RCLONE_S3_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_S3_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_S3_ENDPOINT="$R2_ENDPOINT"
export RCLONE_S3_REGION=auto
# copyto (not copy) so the staged temp dir's name never leaks into the key.
rclone copyto "$STAGE/$REMOTE_NAME" ":s3:$R2_BUCKET/$REMOTE_NAME" --s3-no-check-bucket

echo ">> Published: https://dl.corkkam.com/$REMOTE_NAME"
