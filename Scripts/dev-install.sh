#!/usr/bin/env bash
set -euo pipefail

# ── Local dev install — side-by-side with the production app ──────────────────
#
# Problem this solves: `bundle.sh` + `install.sh` build the *real* app
# (bundle id `app.whispermaster.mac`, name "Whisper Master") and install it to
# `/Applications/Whisper Master.app` — the same identity your testers run. If you
# install that locally you clobber the production copy on your own Mac, and its
# Sparkle updater will happily pull a newer production build right back over your
# local test build.
#
# This script instead produces a DISTINCT app so both can live on your Mac at
# once. It does NOT touch project.yml or Resources/Info.plist — it builds the
# normal product, then patches + re-signs a renamed copy:
#   • bundle id   app.whispermaster.mac  ->  app.whispermaster.mac.dev
#     (macOS, TCC/permissions, UserDefaults and Sparkle all key on bundle id, so
#      the dev app gets its OWN mic/accessibility grants, settings, and history —
#      full isolation from the app your testers use)
#   • name        "Whisper Master"       ->  "Whisper Master Dev"
#     (installs to /Applications/Whisper Master Dev.app; shows separately in the
#      Dock / app switcher)
#   • executable  WhisperMaster          ->  WhisperMasterDev
#     (so quitting/relaunching the dev app never touches the running prod one)
#   • Sparkle auto-update DISABLED (SUFeedURL removed, automatic checks off) so
#     the dev build can never silently update itself into the production build.
#
# Signed with a stable local identity (Apple Development cert if present, else
# ad-hoc) — this is a local build, not for distribution / notarization. A stable
# identity keeps the keychain "Always Allow" grant valid across rebuilds; ad-hoc
# re-prompts every time because its code identity changes each build. Override
# with DEV_SIGN_IDENTITY (set "-" to force ad-hoc).
#
# Usage:
#   bash Scripts/dev-install.sh                 # build (Debug) + install + launch
#   REBUILD=0 bash Scripts/dev-install.sh       # repackage last build, skip xcodebuild
#   RELAUNCH=0 bash Scripts/dev-install.sh       # install without launching
#   CONFIG=Release bash Scripts/dev-install.sh   # optimized build (real latency)
#   DIAGNOSTICS=1 bash Scripts/dev-install.sh    # compile the local session tracer in
#   DEV_SUFFIX="Beta" bash Scripts/dev-install.sh  # -> app.whispermaster.mac.beta / "…Beta"
# ──────────────────────────────────────────────────────────────────────────────

PROD_NAME="Whisper Master"          # what bundle.sh stages
PROD_BIN="WhisperMaster"
PROD_ID="app.whispermaster.mac"

DEV_SUFFIX="${DEV_SUFFIX:-Dev}"     # human-facing suffix
DEV_NAME="${PROD_NAME} ${DEV_SUFFIX}"
DEV_BIN="${PROD_BIN}${DEV_SUFFIX}"
# bundle-id suffix: lowercased, alnum only (a valid reverse-DNS component)
ID_SUFFIX="$(printf '%s' "$DEV_SUFFIX" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"
DEV_ID="${PROD_ID}.${ID_SUFFIX}"

CONFIG="${CONFIG:-Debug}"           # dev default: Debug (fast; enables Debug-only tooling)
RELAUNCH="${RELAUNCH:-1}"
REBUILD="${REBUILD:-1}"

SRC_APP="build/${PROD_NAME}.app"        # produced by bundle.sh (ad-hoc)
STAGE_APP="build/${DEV_NAME}.app"       # patched dev copy we install from
DST_APP="/Applications/${DEV_NAME}.app"

PLB=/usr/libexec/PlistBuddy

cd "$(dirname "$0")/.."

# 1. Build the normal product ad-hoc (no Developer ID / notarization for local).
if [[ "$REBUILD" == "1" || ! -d "$SRC_APP" ]]; then
    echo ">> Building .app via bundle.sh (CONFIG=$CONFIG, ad-hoc)"
    SIGN_IDENTITY=- CONFIG="$CONFIG" bash Scripts/bundle.sh
fi
if [[ ! -d "$SRC_APP" ]]; then
    echo "error: $SRC_APP missing after build" >&2
    exit 1
fi

# 2. Stage a renamed copy and re-badge it as a distinct app.
echo ">> Staging $STAGE_APP"
rm -rf "$STAGE_APP"
cp -R "$SRC_APP" "$STAGE_APP"

INFO="$STAGE_APP/Contents/Info.plist"

# Rename the executable so the two apps have distinct process names.
if [[ -f "$STAGE_APP/Contents/MacOS/$PROD_BIN" ]]; then
    mv "$STAGE_APP/Contents/MacOS/$PROD_BIN" "$STAGE_APP/Contents/MacOS/$DEV_BIN"
fi

echo ">> Re-badging: id=$DEV_ID name=\"$DEV_NAME\" exec=$DEV_BIN, Sparkle off"
$PLB -c "Set :CFBundleIdentifier $DEV_ID"    "$INFO"
$PLB -c "Set :CFBundleExecutable $DEV_BIN"   "$INFO"
$PLB -c "Set :CFBundleName $DEV_NAME"        "$INFO"
$PLB -c "Set :CFBundleDisplayName $DEV_NAME" "$INFO"
# Kill auto-update: the dev build must never pull the production build over itself.
$PLB -c "Set :SUEnableAutomaticChecks false" "$INFO" 2>/dev/null || true
$PLB -c "Delete :SUFeedURL"                  "$INFO" 2>/dev/null || true

# 3. Re-sign — editing Info.plist and renaming the executable invalidate the
#    original seal. Nested frameworks keep their own (unchanged) signatures; we
#    only reseal the top-level bundle.
#
#    Signing identity matters for the KEYCHAIN, not just the seal: macOS ties a
#    keychain item's ACL (what "Always Allow" grants) to the app's *designated
#    requirement*. An ad-hoc signature's requirement is derived from the binary's
#    cdhash, which changes on every rebuild — so Clerk's stored session token
#    prompts "… wants to use your confidential information" again after each
#    dev-install, and "Always Allow" never sticks. Signing with a STABLE identity
#    (a real cert) keeps the designated requirement constant across rebuilds, so
#    one "Always Allow" holds. Override with DEV_SIGN_IDENTITY; set it to "-" to
#    force the old ad-hoc behaviour.
DEV_SIGN_IDENTITY="${DEV_SIGN_IDENTITY:-}"
if [[ -z "$DEV_SIGN_IDENTITY" ]]; then
    # Prefer a stable Apple Development identity if one exists; else fall back
    # to ad-hoc (repeated keychain prompts, but no cert required).
    DEV_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/{print $2; exit}')"
    DEV_SIGN_IDENTITY="${DEV_SIGN_IDENTITY:--}"
fi
if [[ "$DEV_SIGN_IDENTITY" == "-" ]]; then
    echo ">> Re-signing ad-hoc (keychain will re-prompt after each rebuild)"
else
    echo ">> Re-signing with stable identity: $DEV_SIGN_IDENTITY"
fi
codesign --force --sign "$DEV_SIGN_IDENTITY" \
    --entitlements Resources/WhisperMaster.entitlements \
    "$STAGE_APP"
codesign --verify --strict "$STAGE_APP"

# 4. Quit only the DEV instance (matched by its own executable name), replace,
#    relaunch. The production app — if running — is untouched.
if pgrep -x "$DEV_BIN" >/dev/null 2>&1; then
    echo ">> Quitting running ${DEV_NAME}"
    osascript -e "tell application \"${DEV_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 0.6
    if pgrep -x "$DEV_BIN" >/dev/null 2>&1; then
        pkill -x "$DEV_BIN" || true
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
    cp -R "$STAGE_APP" "$DST_APP"
else
    sudo cp -R "$STAGE_APP" "$DST_APP"
fi

xattr -dr com.apple.quarantine "$DST_APP" 2>/dev/null || true

if [[ "$RELAUNCH" == "1" ]]; then
    echo ">> Launching ${DEV_NAME}"
    open "$DST_APP"
fi

echo
echo "Installed ${DST_APP}"
echo "  bundle id : ${DEV_ID}  (separate mic/accessibility grants, settings & history)"
echo "  Sparkle   : disabled   (won't auto-update to the production build)"
echo "Your production ${PROD_NAME}.app is untouched."
