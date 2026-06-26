#!/usr/bin/env bash
set -euo pipefail

# Cuts a Sparkle release: builds + signs the .app, zips it, signs the zip and
# (re)generates appcast.xml with the EdDSA key from the keychain, then uploads
# the archive + appcast to the Cloudflare R2 bucket. Testers' apps then
# auto-update from the public r2.dev feed.
#
# Bump CFBundleShortVersionString / CFBundleVersion in Resources/Info.plist
# before running, or Sparkle won't see it as a newer version.

cd "$(dirname "$0")/.."

APP_NAME="Whisper Master"
APP_PATH="build/${APP_NAME}.app"
STAGE="build/sparkle"
REBUILD="${REBUILD:-1}"

# --- Load R2 credentials ---
# Local runs read .env; CI provides these as environment variables (secrets).
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi
: "${R2_ACCESS_KEY_ID:?missing in .env}"
: "${R2_SECRET_ACCESS_KEY:?missing in .env}"
: "${R2_BUCKET:?missing in .env}"
: "${R2_ENDPOINT:?missing in .env}"
: "${R2_PUBLIC_BASE_URL:?missing in .env}"

# --- Tools ---
command -v rclone >/dev/null || { echo "error: rclone not installed (brew install rclone)" >&2; exit 1; }

# --- Build the signed .app ---
if [[ "$REBUILD" == "1" || ! -d "$APP_PATH" ]]; then
    echo ">> Building app via bundle.sh"
    bash Scripts/bundle.sh
fi

# --- Locate Sparkle's appcast tool (fetched into DerivedData during the build) ---
# Done after the build so the SwiftPM artifacts exist; only scan dirs that are
# present so `find` can't trip `set -e`.
GEN_APPCAST=""
for root in "build/DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"; do
    [[ -d "$root" ]] || continue
    found=$(find "$root" -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1 || true)
    [[ -n "$found" ]] && { GEN_APPCAST="$found"; break; }
done
[[ -n "$GEN_APPCAST" ]] || { echo "error: generate_appcast not found under DerivedData" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
echo ">> Releasing version $VERSION (build $BUILD)"

# --- Zip the app for Sparkle ---
rm -rf "$STAGE"; mkdir -p "$STAGE"
ZIP="$STAGE/WhisperMaster-$VERSION.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

# --- Sign + generate appcast ---
echo ">> Generating appcast"
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    # CI: sign with the exported EdDSA key (no keychain on the runner).
    ED_KEY_FILE="build/.sparkle_ed_key"
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$ED_KEY_FILE"
    trap 'rm -f "$ED_KEY_FILE"' EXIT
    "$GEN_APPCAST" "$STAGE" --ed-key-file "$ED_KEY_FILE" --download-url-prefix "${R2_PUBLIC_BASE_URL%/}/"
    rm -f "$ED_KEY_FILE"; trap - EXIT
else
    # Local: read the private key from the keychain (may prompt once).
    "$GEN_APPCAST" "$STAGE" --download-url-prefix "${R2_PUBLIC_BASE_URL%/}/"
fi

# --- Upload archive + appcast to R2 ---
echo ">> Uploading to R2 bucket: $R2_BUCKET"
export RCLONE_S3_PROVIDER=Cloudflare
export RCLONE_S3_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_S3_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_S3_ENDPOINT="$R2_ENDPOINT"
export RCLONE_S3_REGION=auto
rclone copy "$STAGE/" ":s3:$R2_BUCKET/" --s3-no-check-bucket --progress

echo ""
echo "Released $VERSION:"
echo "  appcast: ${R2_PUBLIC_BASE_URL%/}/appcast.xml"
echo "  archive: ${R2_PUBLIC_BASE_URL%/}/$(basename "$ZIP")"
