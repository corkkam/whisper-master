import ClerkKit
import ClerkKitUI
import SwiftUI

/// The sign-in gate shown at launch and whenever no user is authenticated.
///
/// The whole app is locked behind it — dictation won't start until a user signs
/// in (see `AppDelegate`). It presents Clerk's prebuilt `AuthView`; while Clerk
/// is still restoring a persisted session it shows a spinner, and when no
/// publishable key is configured it shows a setup message instead of a broken
/// sign-in form.
struct AuthGateView: View {
    @Environment(Clerk.self) private var clerk

    /// Called from the "Retry" affordance in the not-loaded / unconfigured state.
    /// (Reconstructed after data loss — the original was a manual edit; wired from
    /// `AuthGateWindow(onRetry:)`, defaulted so callers/previews can omit it.)
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(spacing: 20) {
            // Brand logo only — Clerk's `AuthView` renders its own header
            // ("Continue to Whisper Master" / "Welcome! Sign in to continue")
            // that we can't hide (no public API on AuthView), so repeating the
            // wordmark + tagline here just stacked four near-identical welcome
            // lines. The logo gives the app identity above the card without the
            // echo. If ClerkKitUI ever exposes a header toggle, restore the
            // wordmark and hide Clerk's instead.
            BrandLogo(size: 64)
                .padding(.top, 8)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(WarmBackground())
    }

    @ViewBuilder
    private var content: some View {
        if !ClerkConfig.isConfigured {
            configurationNeeded
                .frame(maxWidth: 360)
        } else if !clerk.isLoaded {
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking your session…")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: 360)
            .padding(.top, 12)
        } else {
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
                .frame(maxWidth: 360, maxHeight: .infinity)
        }
    }

    private var configurationNeeded: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign-in isn’t configured yet")
                .font(Typography.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Add your Clerk publishable key to enable login. Set `ClerkPublishableKey` in Resources/Info.plist (or the `CLERK_PUBLISHABLE_KEY` environment variable) to a `pk_test_…` / `pk_live_…` key from the Clerk dashboard, then relaunch.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.stroke)
        )
    }
}
