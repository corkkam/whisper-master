#!/usr/bin/env bash
set -euo pipefail

# ── Stop the repeated "codesign wants to use your keychain" password prompts ──
#
# When bundle.sh / dev-install.sh sign with a real cert ("Apple Development…"),
# macOS gates codesign's access to that cert's PRIVATE KEY on the key's
# *partition list*. If the list doesn't authorize Apple's codesigning tools,
# every codesign invocation pops a login-keychain password prompt — and clicking
# "Always Allow" frequently doesn't stick, so you get prompted several times per
# build. This is the same lockout CI works around after importing the cert.
#
# The fix (one-time, per Mac): add the Apple codesigning tools to the partition
# list of every signing key in the login keychain, so codesign can read the key
# non-interactively from then on. You type your LOGIN (keychain) password once,
# here — it is never stored or echoed.
#
#   bash Scripts/allow-codesign-keychain.sh
#
# Re-run it only if you change your login password or add a new signing cert.
# ──────────────────────────────────────────────────────────────────────────────

KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"

if [[ ! -e "$KEYCHAIN" ]]; then
    echo "error: keychain not found: $KEYCHAIN" >&2
    exit 1
fi

echo ">> Authorizing Apple codesigning tools for keys in:"
echo "   $KEYCHAIN"
echo ">> Enter your macOS LOGIN password (the one you use to unlock the keychain)."
printf "Password: "
read -rs KC_PW
echo

# apple-tool: + apple: cover the toolchain; codesign: is explicit for /usr/bin/codesign.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KC_PW" \
    "$KEYCHAIN" >/dev/null

unset KC_PW
echo ">> Done. codesign should no longer prompt for this keychain."
echo "   Rebuild with: bash Scripts/dev-install.sh"
