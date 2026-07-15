import AppKit
import ClerkKit
import ClerkKitUI
import SwiftUI

/// The sign-in gate shown at launch and whenever no user is authenticated.
///
/// The whole app is locked behind it — dictation won't start until a user signs
/// in (see `AppDelegate`). It presents Clerk's prebuilt `AuthView` inside warm
/// brand chrome (logo, tagline, waveform motif) so the 520-wide window reads as
/// the product's front door, not a lone form floating in gutters. Three
/// non-happy states are handled explicitly: Clerk still restoring a session
/// (spinner), the restore never arriving (offline → Retry/Quit), and no
/// publishable key configured (a friendly "temporarily unavailable", not a
/// developer note).
struct AuthGateView: View {
    @Environment(Clerk.self) private var clerk

    /// Re-attempt Clerk configuration/session load. The view can't reach the
    /// `AppDelegate`-owned `ClerkConfig.configureIfPossible()` / reconcile, so
    /// this is injected; default no-op keeps previews and snapshots simple.
    var onRetry: () -> Void = {}

    /// Bumped by Retry to restart the loading-timeout task.
    @State private var retryToken = 0
    /// Set when the session restore hasn't finished within the timeout window.
    @State private var waitTimedOut = false

    /// How long to wait for Clerk to restore a persisted session before assuming
    /// the network is unreachable and offering Retry/Quit.
    private let loadTimeout: Duration = .seconds(8)

    var body: some View {
        ZStack {
            Theme.canvasGradient.ignoresSafeArea()

            VStack(spacing: Theme.Space.xl) {
                brandHeader
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Theme.Space.xxl)
        }
        // Restart the loading timeout on first appearance and on every Retry.
        .task(id: retryToken) {
            guard ClerkConfig.isConfigured else { return }
            waitTimedOut = false
            try? await Task.sleep(for: loadTimeout)
            if !clerk.isLoaded { waitTimedOut = true }
        }
    }

    // MARK: Brand chrome (fills the width the bare form used to leave empty)

    private var brandHeader: some View {
        VStack(spacing: 14) {
            BrandLogo(size: 64, cornerRadius: 15)
            VStack(spacing: 6) {
                Text("Whisper Master")
                    .font(Typography.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text("Local-first dictation for macOS")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            OnboardingWaveform(ambient: true)
                .frame(height: 26)
                .frame(maxWidth: 300)
        }
        .padding(.top, Theme.Space.sm)
    }

    // MARK: State machine

    @ViewBuilder
    private var content: some View {
        if !ClerkConfig.isConfigured {
            // A missing/placeholder key is an operator problem, not the user's —
            // log the real cause but show them something reassuring.
            unavailable
        } else if waitTimedOut, !clerk.isLoaded {
            offline
        } else if !clerk.isLoaded {
            checkingSession
        } else {
            signInForm
        }
    }

    private var checkingSession: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking your session…")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: 360)
        .padding(.top, 12)
    }

    private var signInForm: some View {
        VStack(spacing: Theme.Space.lg) {
            // Only shown while signed out (AppDelegate closes the window on
            // sign-in), so go straight to Clerk's prebuilt sign-in / sign-up UI.
            // isDismissible: false — the app is gated, so there's no dismiss
            // affordance; we close the window ourselves once a user signs in.
            //
            // maxWidth MUST be finite: ClerkKitUI's `SocialButtonRowsLayout`
            // does `Int(containerWidth / itemWidth)`, so an infinite width
            // proposal (which SwiftUI hands it during measurement) becomes
            // `Int(.infinity)` and traps ("Double value cannot be converted to
            // Int… infinite or NaN") — a hard SIGTRAP crash the moment the
            // sign-in UI lays out. Bounding the width keeps the proposal finite.
            AuthView(isDismissible: false)
                .frame(maxWidth: 360)

            trustExplainer
        }
        .frame(maxWidth: 360)
    }

    /// The one line that answers "why does local-first dictation need a login?".
    private var trustExplainer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.laptopcomputer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Transcription always runs on your Mac — sign-in just unlocks the app.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    // MARK: Non-happy states

    private var offline: some View {
        stateCard(
            icon: "wifi.slash",
            title: "Couldn’t reach sign-in",
            message: "Check your connection and try again."
        )
    }

    private var unavailable: some View {
        stateCard(
            icon: "person.crop.circle.badge.exclamationmark",
            title: "Sign-in is temporarily unavailable",
            message: "Please try again in a moment."
        )
    }

    /// Shared error card with a prominent Retry and a quiet Quit (Cmd-Q also
    /// works — you can leave the gate, just not bypass it).
    private func stateCard(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.warning)
            VStack(spacing: 6) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                PrimaryButton(title: "Retry", icon: "arrow.clockwise") { retry() }
                SecondaryButton(title: "Quit") { NSApp.terminate(nil) }
            }
        }
        .frame(maxWidth: 360)
        .padding(Theme.Space.xl)
        .card()
    }

    private func retry() {
        waitTimedOut = false
        retryToken += 1
        onRetry()
    }
}
