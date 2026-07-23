#!/usr/bin/env bash
# Shared release-channel config — SOURCED by bundle.sh / release.sh /
# make-dmg.sh / publish-dmg.sh (never run directly). Given CHANNEL
# (stable|beta|dev) it sets the channel-specific app name, bundle id, Sparkle
# feed, appcast file name and DMG share name so a beta/dev build ships
# SIDE-BY-SIDE with stable and can never touch stable's appcast.xml.
#
#   CHANNEL=stable  (default)  → "Whisper Master",       app.whispermaster.mac
#   CHANNEL=beta               → "Whisper Master Beta",  app.whispermaster.mac.beta
#   CHANNEL=dev                → "Whisper Master Dev",   app.whispermaster.mac.dev
#
# Beta and stable use the SAME production Clerk instance + `public` Supabase
# schema (BuildEnvironment.isProduction treats any `.beta` bundle as production);
# they differ only by Clerk publicMetadata.betaAccess, which routes each user to
# the matching feed. The `dev` channel is the `dev` git branch's build (shipped
# by CI on a version-bump push to `dev`) and served on the development
# deployment; a `.dev` bundle always polls the dev feed regardless of the flag.
# Keep the URLs here in lock-step with UpdateChannel in
# Sources/WhisperMaster/Auth/BetaAccess.swift.

CHANNEL="${CHANNEL:-stable}"

case "$CHANNEL" in
    stable)
        CH_APP_NAME="Whisper Master"
        CH_BUNDLE_ID="app.whispermaster.mac"
        CH_SU_FEED_URL="https://model.scoopscore.in/appcast.xml"
        CH_APPCAST_NAME="appcast.xml"
        CH_DMG_STABLE_NAME="WhisperMaster.dmg"
        ;;
    beta)
        CH_APP_NAME="Whisper Master Beta"
        CH_BUNDLE_ID="app.whispermaster.mac.beta"
        CH_SU_FEED_URL="https://pub-98e94ebcf8904c07b38b85605ad49284.r2.dev/appcast-beta.xml"
        CH_APPCAST_NAME="appcast-beta.xml"
        CH_DMG_STABLE_NAME="WhisperMaster-beta.dmg"
        ;;
    dev)
        CH_APP_NAME="Whisper Master Dev"
        CH_BUNDLE_ID="app.whispermaster.mac.dev"
        CH_SU_FEED_URL="https://model.scoopscore.in/appcast-dev.xml"
        CH_APPCAST_NAME="appcast-dev.xml"
        CH_DMG_STABLE_NAME="WhisperMaster-dev.dmg"
        ;;
    *)
        echo "error: unknown CHANNEL '$CHANNEL' (expected: stable | beta | dev)" >&2
        exit 1
        ;;
esac
