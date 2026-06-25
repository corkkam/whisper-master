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
if [[ ! -f .env ]]; then
    echo "error: .env not found (copy .env.example and fill it in)" >&2
    exit 1
fi
set -a; source .env; set +a
: "${R2_ACCESS_KEY_ID:?missing in .env}"
: "${R2_SECRET_ACCESS_KEY:?missing in .env}"
: "${R2_BUCKET:?missing in .env}"
: "${R2_ENDPOINT:?missing in .env}"
: "${R2_PUBLIC_BASE_URL:?missing in .env}"

# --- Tools ---
command -v rclone >/dev/null || { echo "error: rclone not installed (brew install rclone)" >&2; exit 1; }
GEN_APPCAST=$(find build/DerivedData "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)
[[ -n "$GEN_APPCAST" ]] || { echo "error: generate_appcast not found — build once first" >&2; exit 1; }

# --- Build the signed .app ---
if [[ "$REBUILD" == "1" || ! -d "$APP_PATH" ]]; then
    echo ">> Building app via bundle.sh"
    bash Scripts/bundle.sh
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
echo ">> Releasing version $VERSION (build $BUILD)"

# --- Zip the app for Sparkle ---
rm -rf "$STAGE"; mkdir -p "$STAGE"
ZIP="$STAGE/WhisperMaster-$VERSION.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

# --- Sign + generate appcast (EdDSA private key read from the keychain) ---
echo ">> Generating appcast (may prompt for keychain access — click Always Allow)"
"$GEN_APPCAST" "$STAGE" --download-url-prefix "${R2_PUBLIC_BASE_URL%/}/"

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
