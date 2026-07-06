#!/usr/bin/env bash
set -euo pipefail

# Notarizes and staples a .app or .dmg with Apple's notary service, so first
# launch (and the DMG mount) skip the Gatekeeper warning — no more one-time
# `xattr -dr com.apple.quarantine`.
#
# Usage: Scripts/notarize.sh <path-to-.app-or-.dmg>
#
# Credentials (first match wins). Set these in .env (local) or as CI env vars:
#   1. App Store Connect API key (recommended):
#        NOTARY_KEY_P8   = path to the AuthKey_XXXX.p8 file
#        NOTARY_KEY_ID   = the key's Key ID
#        NOTARY_ISSUER   = the issuer UUID
#   2. Keychain profile (simplest local setup):
#        NOTARY_PROFILE  = name saved via `xcrun notarytool store-credentials`
#   3. Apple ID + app-specific password:
#        NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID
#
# If none are set, notarization is SKIPPED (exit 0) so collaborator/ad-hoc
# builds still succeed — the artifact just isn't notarized.

TARGET="${1:?usage: notarize.sh <path-to-.app-or-.dmg>}"
[[ -e "$TARGET" ]] || { echo "error: $TARGET not found" >&2; exit 1; }

CRED=()
if [[ -n "${NOTARY_KEY_P8:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    CRED=(--key "$NOTARY_KEY_P8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    CRED=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
    CRED=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
    echo ">> notarize: no NOTARY_* credentials set — skipping notarization for $(basename "$TARGET")" >&2
    exit 0
fi

# notarytool wants a zip for a .app; a .dmg is submitted directly.
SUBMIT="$TARGET"
CLEANUP=""
if [[ "$TARGET" == *.app ]]; then
    SUBMIT="${TARGET%.app}.notary.zip"
    rm -f "$SUBMIT"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
    CLEANUP="$SUBMIT"
fi

echo ">> Submitting $(basename "$SUBMIT") to Apple notary service (can take a few minutes)…"
# `notarytool submit --wait` exits 0 even when the verdict is "Invalid", so
# inspect the status text ourselves and dump the detailed log on any non-Accepted
# result rather than blindly stapling a missing ticket.
OUT="$(xcrun notarytool submit "$SUBMIT" "${CRED[@]}" --wait 2>&1)" || true
echo "$OUT"
if ! grep -q "status: Accepted" <<<"$OUT"; then
    SID="$(grep -m1 '  id:' <<<"$OUT" | awk '{print $2}')"
    echo "error: notarization was not accepted — detailed log:" >&2
    [[ -n "$SID" ]] && xcrun notarytool log "$SID" "${CRED[@]}" >&2 || true
    [[ -n "$CLEANUP" ]] && rm -f "$CLEANUP"
    exit 1
fi

echo ">> Stapling ticket to $(basename "$TARGET")"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

[[ -n "$CLEANUP" ]] && rm -f "$CLEANUP"
echo ">> Notarized + stapled: $TARGET"
