#!/usr/bin/env bash
set -euo pipefail

# Cuts a Sparkle release: builds + signs the .app, zips it, signs the zip and
# (re)generates appcast.xml with the EdDSA key from the keychain, then uploads
# the archive + appcast to the Cloudflare R2 bucket. Testers' apps then
# auto-update from the dl.corkkam.com feed.
#
# Bump CFBundleShortVersionString / CFBundleVersion in Resources/Info.plist
# before running, or Sparkle won't see it as a newer version.

cd "$(dirname "$0")/.."

# Release channel (stable|beta). Beta builds a side-by-side bundle, generates
# appcast-beta.xml (never touching stable's appcast.xml), and uploads only the
# beta artifacts. See channel.sh + CLAUDE.md → beta channel.
source "$(dirname "$0")/channel.sh"

APP_NAME="$CH_APP_NAME"
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

# --- The host you upload to must be the host the app reads ---
#
# CLAUDE.md says the public host lives in four places that must move together.
# Nothing enforced it, and the drift is silent in the worst way: the credentials
# and R2_PUBLIC_BASE_URL point at one bucket while the shipped binary reads
# another, so an upload "succeeds" and the artifact is a 404 to every user. That
# is exactly how s1-mini-4bit came to be published where the app never looks —
# a stale .env survived the move to dl.corkkam.com.
#
# ModelInstaller is the source of truth because it is compiled into the bundle.
_app_host="$(sed -n 's|.*"https://\([^/"]*\)/models".*|\1|p' \
    Sources/WhisperMaster/ModelInstall/ModelInstaller.swift | head -1)"
_env_host="${R2_PUBLIC_BASE_URL#*://}"; _env_host="${_env_host%%/*}"
if [[ -n "$_app_host" && "$_app_host" != "$_env_host" ]]; then
    cat >&2 <<EOF
error: R2 host mismatch — this upload would go somewhere the app never reads.

  R2_PUBLIC_BASE_URL : $_env_host   (where this script uploads)
  ModelInstaller.swift: $_app_host   (where the shipped app downloads)

Fix by pointing R2_PUBLIC_BASE_URL *and* the R2_* credentials at $_app_host,
or by moving the app's host — Scripts/channel.sh, Auth/BetaAccess.swift and
ModelInstall/ModelInstaller.swift together, after copying models/ across.
Override for a deliberate one-off with ALLOW_HOST_MISMATCH=1.
EOF
    [[ "${ALLOW_HOST_MISMATCH:-0}" == "1" ]] || exit 1
fi

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
echo ">> Releasing version $VERSION (build $BUILD) on the $CHANNEL channel"

# A beta/dev release MUST carry a matching pre-release version tag (e.g.
# 1.2.8-beta.1 / 1.2.8-dev.1). This keeps the archive filename
# (WhisperMaster-<version>.zip) distinct from every stable archive at the R2
# bucket root, so a beta/dev upload can never overwrite a stable zip whose bytes
# an installed app / the CDN still expects.
if [[ "$CHANNEL" != "stable" && "$VERSION" != *-${CHANNEL}* ]]; then
    echo "error: $CHANNEL release version '$VERSION' must contain a '-${CHANNEL}.N' pre-release tag" >&2
    echo "       Bump CFBundleShortVersionString in Resources/Info.plist to e.g. ${VERSION}-${CHANNEL}.1" >&2
    exit 1
fi

# --- Upload debug symbols for crash symbolication ---
# Without this every native crash from this build arrives in PostHog as hex
# addresses, forever — the dSYM only exists on the machine that compiled it, and
# once this build directory is gone the stacks can never be recovered. Runs
# before notarization so a failure here costs a rebuild, not a republished
# version (see the "never republish a version number" rule in CLAUDE.md).
#
# PostHog ships the uploader inside the SDK checkout, so the CLI flags stay in
# step with the SDK rather than being hand-rolled here. It reads Xcode build
# settings from the environment; we set them explicitly because the ones baked
# into the project are wrong for this purpose: MARKETING_VERSION /
# CURRENT_PROJECT_VERSION in project.yml are inert (Info.plist is the authority),
# and PRODUCT_BUNDLE_IDENTIFIER is always the *stable* id because bundle.sh
# re-badges beta/dev on the staged copy after the build. Passing the staged
# app's real values is what keeps a beta's symbols attached to the beta release
# instead of silently overwriting stable's.
UPLOAD_SYMBOLS=""
for root in "build/DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"; do
    [[ -d "$root" ]] || continue
    found=$(find "$root" -path '*posthog-ios/build-tools/upload-symbols.sh' 2>/dev/null | head -1 || true)
    [[ -n "$found" ]] && { UPLOAD_SYMBOLS="$found"; break; }
done

# Scoped to the configuration bundle.sh actually built (it honours $CONFIG too),
# so a stale Debug dSYM left in DerivedData can never be uploaded and tagged as
# this release — its symbols wouldn't match the shipped binary, which is worse
# than having none at all.
DSYM=$(find "build/DerivedData/Build/Products/${CONFIG:-Release}" -name '*.app.dSYM' -type d 2>/dev/null | head -1 || true)

if [[ -z "${POSTHOG_CLI_API_KEY:-}" ]]; then
    echo ">> WARNING: POSTHOG_CLI_API_KEY unset — skipping dSYM upload."
    echo "   Native crashes from $VERSION will be UNSYMBOLICATED and cannot be"
    echo "   symbolicated later. See .env.example → POSTHOG_CLI_API_KEY."
elif [[ -z "$UPLOAD_SYMBOLS" || -z "$DSYM" ]]; then
    echo ">> WARNING: skipping dSYM upload (uploader or dSYM not found)."
    [[ -n "$UPLOAD_SYMBOLS" ]] || echo "   no posthog-ios/build-tools/upload-symbols.sh under DerivedData"
    [[ -n "$DSYM" ]] || echo "   no *.app.dSYM under build/DerivedData/Build/Products (is DEBUG_INFORMATION_FORMAT dwarf-with-dsym?)"
else
    echo ">> Uploading dSYM to PostHog ($CH_BUNDLE_ID $VERSION build $BUILD)"
    # A configured upload that *fails* is a real error and stops the release —
    # nothing has been published yet, so re-running costs only a rebuild.
    # `CONFIGURATION` is deliberately left unset: the script skips non-Release
    # builds, and treats "unset" as an explicit CI/manual invocation.
    DWARF_DSYM_FOLDER_PATH="$(dirname "$DSYM")" \
    DWARF_DSYM_FILE_NAME="$(basename "$DSYM")" \
    PRODUCT_BUNDLE_IDENTIFIER="$CH_BUNDLE_ID" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    bash "$UPLOAD_SYMBOLS"
fi

# --- Notarize + staple the app before zipping ---
# Stapling embeds the ticket inside the .app, so it travels in the Sparkle zip
# and the update installs without any Gatekeeper prompt. No-op if NOTARY_* unset.
echo ">> Notarizing the app"
bash Scripts/notarize.sh "$APP_PATH"

# --- Zip the app for Sparkle ---
rm -rf "$STAGE"; mkdir -p "$STAGE"

# ⚠️ Seed the stage with the feed already published on this channel BEFORE
# staging the new zip. generate_appcast rebuilds the appcast from whatever it
# finds in the directory, so a stage holding only this run's archive produces a
# ONE-ITEM feed — and uploading that silently deletes every older item from the
# live appcast. That was harmless while each channel owned a single-item feed of
# its own; it is fatal now that stable and beta share appcast.xml, because a beta
# release would drop the stable item and strand every user who has not updated.
# With the published feed present, generate_appcast reports "removed 0 old
# updates" and copies prior items through verbatim — signatures, enclosure URLs
# and all — without needing their archives on disk.
#
# Always seeded as "appcast.xml": that is the name generate_appcast reads and
# writes. A channel served under another name (dev) is renamed after generation,
# below.
if curl -fsS "${R2_PUBLIC_BASE_URL%/}/$CH_APPCAST_NAME" -o "$STAGE/appcast.xml"; then
    echo ">> Seeded stage from published $CH_APPCAST_NAME ($(grep -c '<item>' "$STAGE/appcast.xml") existing item(s))"
    # ⚠️ Seed BOTH names, because we cannot know which one generate_appcast will
    # read. Newer versions derive the feed filename from the app's SUFeedURL, so
    # on the dev channel they open "appcast-dev.xml", never see the history we
    # just wrote to "appcast.xml", and emit a fresh one-item feed. The rename
    # block below then finds both files, keeps the channel-named one and deletes
    # the seeded one — so the seeding step silently did nothing and the upload
    # wiped the feed. That is what happened to 1.2.0-dev.1 on 2026-09-06: the run
    # logged "Seeded stage ... (1 existing item(s))" and "Wrote 1 new update ...
    # removed 0 old updates in appcast-dev.xml", and the published feed came back
    # holding one item. Stable and beta were never exposed to it: they are served
    # as "appcast.xml", so the seed and the derived name already agree.
    if [[ "$CH_APPCAST_NAME" != "appcast.xml" ]]; then
        cp "$STAGE/appcast.xml" "$STAGE/$CH_APPCAST_NAME"
    fi
else
    rm -f "$STAGE/appcast.xml"
    echo ">> No published $CH_APPCAST_NAME to seed from — generating a fresh feed"
fi

ZIP="$STAGE/WhisperMaster-$VERSION.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

# --- Sign + generate appcast ---
echo ">> Generating appcast"
# ⚠️ This MUST stay gated on $CI. Line ~26 does `set -a; source .env; set +a`, so
# a SPARKLE_ED_PRIVATE_KEY sitting in .env is exported on *local* runs too — and
# without the $CI test this branch won here, making the keychain path below dead
# code and signing every local release from a plaintext file on disk. The key is
# supposed to live in the login keychain locally and in a GitHub Actions secret
# on CI, and nowhere else. Do not put it back in .env.
# Beta items carry <sparkle:channel>beta</sparkle:channel>; stable items carry no
# channel at all. Sparkle offers an UNTAGGED item to everyone and a tagged one
# only to an updater that allows that channel (SUAppcastDriver.m, ~line 487), so
# this single flag is what keeps a beta release invisible to stable users while
# still letting a beta user receive stable releases. `dev` keeps its own separate
# feed and needs no tag.
GEN_ARGS=(--download-url-prefix "${R2_PUBLIC_BASE_URL%/}/")
if [[ "$CHANNEL" == "beta" ]]; then
    GEN_ARGS+=(--channel beta)
fi

if [[ -n "${CI:-}" && -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    # CI only: sign with the exported EdDSA key (no keychain on the runner).
    ED_KEY_FILE="build/.sparkle_ed_key"
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$ED_KEY_FILE"
    trap 'rm -f "$ED_KEY_FILE"' EXIT
    "$GEN_APPCAST" "$STAGE" --ed-key-file "$ED_KEY_FILE" "${GEN_ARGS[@]}"
    rm -f "$ED_KEY_FILE"; trap - EXIT
else
    # Local: read the private key from the keychain (may prompt once).
    "$GEN_APPCAST" "$STAGE" "${GEN_ARGS[@]}"
fi

# generate_appcast writes "appcast.xml" on older versions and the SUFeedURL-derived
# name on newer ones. A channel served under another name (dev) is renamed before
# upload if it needs it. Beta now shares stable's appcast.xml, so
# it does NOT rename — its items are told apart by <sparkle:channel>, not by
# living in a separate file.
if [[ "$CH_APPCAST_NAME" != "appcast.xml" ]]; then
    # Older generate_appcast always writes "appcast.xml"; newer versions derive
    # the feed filename from the app's SUFeedURL and may already emit
    # "$CH_APPCAST_NAME" directly. Handle both without failing.
    if [[ -f "$STAGE/appcast.xml" && ! -f "$STAGE/$CH_APPCAST_NAME" ]]; then
        mv "$STAGE/appcast.xml" "$STAGE/$CH_APPCAST_NAME"
    elif [[ -f "$STAGE/appcast.xml" && -f "$STAGE/$CH_APPCAST_NAME" ]]; then
        rm -f "$STAGE/appcast.xml"   # keep the channel-named feed, drop the generic one
    fi
    [[ -f "$STAGE/$CH_APPCAST_NAME" ]] || { echo "error: expected $CH_APPCAST_NAME was not produced" >&2; exit 1; }
fi

# --- Assert the enclosure is actually signed ---
# generate_appcast only *warns* ("SUPublicEDKey ... does not match key EdDSA in
# the Keychain") and still exits 0 when the signing key doesn't match the key
# baked into the app — it just omits sparkle:edSignature. An unsigned enclosure
# is an update no installed app will accept, so the release "succeeds" while
# silently breaking every updater. This bit 1.2.8-beta.5. Fail before upload.
# ⚠️ Scoped to THIS release's enclosure line, not the whole file. A merged feed
# already contains older, correctly signed items, so a file-wide grep passes even
# when the new item is unsigned — which is the exact failure this guard exists to
# catch (it bit 1.2.8-beta.5). generate_appcast puts the enclosure URL and its
# sparkle:edSignature on one line, so matching the archive name pins the check to
# the right item.
FEED="$STAGE/$CH_APPCAST_NAME"
if ! grep -F "WhisperMaster-$VERSION.zip" "$FEED" | grep -q 'sparkle:edSignature='; then
    echo "error: the $VERSION item in $CH_APPCAST_NAME carries no sparkle:edSignature — nothing was uploaded." >&2
    echo "       The EdDSA private key used for signing does not match SUPublicEDKey" >&2
    echo "       in the built app. Reconcile them before releasing:" >&2
    echo "         app SUPublicEDKey : $(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PATH/Contents/Info.plist" 2>/dev/null)" >&2
    # Name the source only — never interpolate the key itself into a log.
    if [[ -n "${CI:-}" && -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
        echo "         signing source    : SPARKLE_ED_PRIVATE_KEY (CI secret)" >&2
    else
        echo "         signing source    : login keychain" >&2
    fi
    exit 1
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
echo "Released $VERSION on the $CHANNEL channel:"
echo "  appcast: ${R2_PUBLIC_BASE_URL%/}/$CH_APPCAST_NAME"
echo "  archive: ${R2_PUBLIC_BASE_URL%/}/$(basename "$ZIP")"

# --- Grade this build, and publish the score against the version ---
#
# Launches the bundle we just built with WM_EVAL_CASES set, pushes every case
# through the real shipped cleanup pipeline, and posts the scores to
# whisper.corkkam.com/eval tagged with $VERSION and $CHANNEL. Doing it here
# rather than by hand is the whole point: "how did 1.1.0-beta.9 score" only has
# an answer if something records it at release time.
#
# Deliberately LAST and deliberately non-fatal. Everything above is already
# published, and in CI the DMG, the What's New manifest, the announcement and
# the release tag all come after this script. A flaky twenty-minute eval must
# not be able to skip any of them. Set EVAL_REQUIRED=1 to make it a gate.
#
# On by default for stable and beta, off for dev: dev ships on every version
# bump to the dev branch, and a score per internal build is noise on a public
# page. RUN_EVAL=0 / RUN_EVAL=1 overrides either way.
#
# Text suite only. The audio suite needs ffmpeg, a TTS pass and a LibriSpeech
# download, none of which belong in a release; run that one by hand against
# .eval-scratch/audio_cases.jsonl. EVAL_CASES overrides.
#
# LOCAL RUNS: this quits and relaunches the app it grades. Cutting a stable
# release from your own machine therefore takes your daily driver down for the
# length of the run. RUN_EVAL=0 if you would rather it did not.
case "$CHANNEL" in
    stable|beta) EVAL_DEFAULT=1 ;;
    *)           EVAL_DEFAULT=0 ;;
esac

if [[ "${RUN_EVAL:-$EVAL_DEFAULT}" == "1" ]]; then
    echo ""
    echo ">> Grading $VERSION ($CHANNEL) — this loads the cleanup model and runs every case"
    if EVAL_VERSION="$VERSION" EVAL_CHANNEL="$CHANNEL" APP="$APP_PATH" \
        bash eval/text-cleanup/run-eval.sh \
            "${EVAL_CASES:-eval/text-cleanup/cases.jsonl}" \
            "$VERSION ($CHANNEL)"; then
        echo ">> Score published: https://whisper.corkkam.com/eval"
    elif [[ -n "${EVAL_REQUIRED:-}" ]]; then
        echo "error: the eval failed and EVAL_REQUIRED is set." >&2
        exit 1
    else
        echo ">> WARNING: the eval did not finish. $VERSION is released and published;" >&2
        echo "   it just carries no score on /eval. Re-run it by hand:" >&2
        echo "     EVAL_VERSION=$VERSION EVAL_CHANNEL=$CHANNEL APP=\"$APP_PATH\" \\" >&2
        echo "       bash eval/text-cleanup/run-eval.sh" >&2
    fi
else
    echo ">> RUN_EVAL=0 — skipping the eval. $VERSION will carry no score on /eval."
fi
