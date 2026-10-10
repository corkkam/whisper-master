# Security policy

Whisper Master is a macOS dictation app whose core promise is that audio never
leaves the Mac. A bug that breaks that promise is a security bug.

## Report a vulnerability

Report privately. Do **not** open a public issue, pull request or discussion.

Use GitHub private vulnerability reporting: the **Security** tab of this repository,
then **Report a vulnerability**. Include the version (Settings > About), macOS
version, steps to reproduce, and the impact you expect.

We reply within 3 working days, and we keep you informed until the fix ships. We
credit you in the advisory unless you ask us not to.

## Supported versions

Only the latest stable release on the Sparkle feed gets fixes. Beta and dev builds
get fixes through their next build.

## In scope

- Audio, transcripts, notes or clipboard content leaving the Mac without the user's choice
- The Sparkle update chain (feed, archive signatures, the R2 download host)
- The remote transcription server and peer discovery (`Sources/WhisperMaster/Server/`, `Mesh/`)
- The Clerk sign-in gate, OAuth redirects, connector tokens, keychain use
- URL scheme and deep-link handlers, paste and Accessibility abuse
- The GitHub Actions workflows in this repository

## Out of scope

- Attacks that need an already compromised Mac or admin access to it
- Publishable keys that are public by design (Clerk `pk_` keys)
- Missing hardening with no exploit path
- Denial of service from a local user against their own install
