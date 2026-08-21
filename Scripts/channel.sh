#!/usr/bin/env bash
# Shared release-channel config — SOURCED by bundle.sh / release.sh /
# make-dmg.sh / publish-dmg.sh (never run directly). Given CHANNEL
# (stable|beta|dev) it sets the channel-specific app name, bundle id, Sparkle
# feed, appcast file name and DMG share name. Only `dev` ships SIDE-BY-SIDE;
# beta is deliberately identical to stable so Sparkle can update between them.
#
#   CHANNEL=stable  (default)  → "Whisper Master",       app.whispermaster.mac
#   CHANNEL=beta               → "Whisper Master",       app.whispermaster.mac  (same bundle!)
#   CHANNEL=dev                → "Whisper Master Dev",   app.whispermaster.mac.dev
#
# Beta and stable are ONE installed app: one bundle id, one name, one appcast.
# The channel lives in the version string (`-beta.N`) and in the item's
# <sparkle:channel> tag, and each user's Clerk publicMetadata.betaAccess decides
# which items Sparkle will accept. Only `dev` is still re-badged side-by-side.
# Beta and stable therefore also share the production Clerk instance + `public`
# Supabase schema, as they always did.
#
# The `dev` channel is the `dev` git branch's build (shipped by CI on a
# version-bump push to `dev`) and served on the development deployment; a `.dev`
# bundle always polls the dev feed regardless of the flag.
# Keep the URLs here in lock-step with UpdateChannel in
# Sources/WhisperMaster/Auth/BetaAccess.swift.

CHANNEL="${CHANNEL:-stable}"

case "$CHANNEL" in
    stable)
        CH_APP_NAME="Whisper Master"
        CH_BUNDLE_ID="app.whispermaster.mac"
        CH_SU_FEED_URL="https://dl.corkkam.com/appcast.xml"
        CH_APPCAST_NAME="appcast.xml"
        CH_DMG_STABLE_NAME="WhisperMaster.dmg"
        ;;
    beta)
        # Beta is the SAME installed app as stable — same bundle id, same name,
        # same feed — and differs only by the `-beta.N` marker in the version and
        # by <sparkle:channel>beta</sparkle:channel> on its appcast item. That is
        # what lets a Clerk `betaAccess` flip move a user between the two tracks
        # with no reinstall (see BetaAccess.allowedChannels). Re-badging it into
        # a side-by-side bundle is exactly what made that impossible: Sparkle
        # only installs an archive holding a bundle whose file name or id matches
        # the host, so a `…mac.beta` archive can never land on a `…mac` install.
        # The DMG keeps its own name — it is the one-time manual download that
        # moves an old side-by-side tester onto this unified build.
        CH_APP_NAME="Whisper Master"
        CH_BUNDLE_ID="app.whispermaster.mac"
        CH_SU_FEED_URL="https://dl.corkkam.com/appcast.xml"
        CH_APPCAST_NAME="appcast.xml"
        CH_DMG_STABLE_NAME="WhisperMaster-beta.dmg"
        ;;
    dev)
        CH_APP_NAME="Whisper Master Dev"
        CH_BUNDLE_ID="app.whispermaster.mac.dev"
        CH_SU_FEED_URL="https://dl.corkkam.com/appcast-dev.xml"
        CH_APPCAST_NAME="appcast-dev.xml"
        CH_DMG_STABLE_NAME="WhisperMaster-dev.dmg"
        ;;
    *)
        echo "error: unknown CHANNEL '$CHANNEL' (expected: stable | beta | dev)" >&2
        exit 1
        ;;
esac
