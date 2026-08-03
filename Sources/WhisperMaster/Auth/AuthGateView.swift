import ClerkKit
import ClerkKitUI
import SwiftUI

/// The sign-in gate shown at launch and whenever no user is authenticated.
///
/// The whole app is locked behind it — dictation won't start until a user signs
/// in (see `AppDelegate`) — so this window is the first thing a new customer sees
/// of the product, and it is treated as a designed surface rather than a form.
/// Three things carry that:
///
/// - **The card is ours.** `AuthView` is Clerk's prebuilt flow (every step of it:
///   codes, MFA, sign-up, recovery — not something to hand-roll), but it renders
///   inside our own panel chrome and under `ClerkAppearance.theme`, so its type,
///   palette and geometry are the app's.
/// - **The state has a readout.** The mono line above the card names which of the
///   three states you're in — setup needed / checking your session / sign in
///   required — instead of leaving a spinner to speak for itself. Its dot follows
///   the accent rule: ember when the app is waiting on *you*, signal when it's the
///   machine's turn, danger when the build is misconfigured.
/// - **The footer answers the two questions this window raises**: where does my
///   voice go, and how do I leave. Neither had an answer here before.
///
/// Clerk's `AuthView` renders its own header ("Continue to Whisper Master" /
/// "Welcome! Sign in to continue") with no public toggle, so there is deliberately
/// **no second headline** in the surrounding chrome — that echo is what the
/// previous version of this view removed a wordmark to avoid. The brand mark goes
/// *inside* the card through Clerk's own logo slot (`.clerkAppIcon`), which is why
/// nothing floats above it any more.
struct AuthGateView: View {
    @Environment(Clerk.self) private var clerk

    /// Re-runs Clerk configuration + reconciles from the `AppDelegate`, which the
    /// SwiftUI view can't reach itself. Wired to the "Try again" affordance in the
    /// unconfigured and not-yet-loaded states — the two places where the gate can
    /// otherwise sit there with nothing for the user to do.
    var onRetry: () -> Void = {}

    /// What the gate is currently waiting on. Ordered by severity, matching the
    /// branch order of `content` below — keep the two in sync.
    private enum Waiting {
        /// No publishable key: a build problem, not something the user can sign past.
        case configuration
        /// Clerk is still restoring a persisted session.
        case session
        /// Signed out. The ordinary case.
        case user

        var label: String {
            switch self {
            case .configuration: "Setup needed"
            case .session: "Checking your session"
            case .user: "Sign in required"
            }
        }

        /// Ember when the app is waiting on the person, signal when it's waiting on
        /// itself, danger when it can't proceed at all.
        var tint: Color {
            switch self {
            case .configuration: Theme.danger
            case .session: Theme.accent2
            case .user: Theme.accent
            }
        }
    }

    private var waiting: Waiting {
        if !ClerkConfig.isConfigured { return .configuration }
        if !clerk.isLoaded { return .session }
        return .user
    }

    var body: some View {
        ZStack {
            WarmBackground()

            VStack(alignment: .leading, spacing: 0) {
                statusRow

                Spacer(minLength: Theme.Space.xl)
                card.frame(maxWidth: .infinity)
                Spacer(minLength: Theme.Space.xl)

                footer
            }
            .padding(Theme.Space.xl)
            // Clears the transparent full-size titlebar the window keeps for
            // dragging (its buttons are hidden, so nothing else marks that strip).
            .padding(.top, Theme.Space.md)
        }
        .environment(\.clerkTheme, ClerkAppearance.theme)
    }

    // MARK: - State readout

    private var statusRow: some View {
        HStack(spacing: Theme.Space.sm) {
            Circle()
                .fill(waiting.tint)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(waiting.label)
                .monoLabel()
                .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The card

    /// Panel chrome built from the same recipe as `glassCard` — hairline, deep
    /// soft lift — but with an opaque fill, because Clerk paints its own
    /// background across the content and a frosted surface behind it would be
    /// invisible work.
    private var card: some View {
        content
            .frame(width: 380)
            .background(Theme.surface)
            .overlay(alignment: .top) { rail }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
            .shadow(
                color: Theme.shadowPanel.color,
                radius: Theme.shadowPanel.radius,
                x: Theme.shadowPanel.x,
                y: Theme.shadowPanel.y
            )
    }

    /// The card's one flourish, and it says something: warm human voice on the
    /// left running into cool machine on the right, which is the product argument
    /// the whole palette encodes. It also does the job the glass top-highlight
    /// does elsewhere — giving the panel a lit top edge so it reads as an object.
    private var rail: some View {
        LinearGradient(
            colors: [Theme.Ember.base, Theme.Signal.base],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch waiting {
        case .configuration:
            configurationNeeded
        case .session:
            checkingSession
        case .user:
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
                // Clerk's own logo slot, so the mark sits inside the card with the
                // title instead of floating above it as a second lockup.
                .clerkAppIcon(BrandAsset.logo.map { Image(nsImage: $0) })
        }
    }

    private var checkingSession: some View {
        VStack(spacing: Theme.Space.md) {
            ProgressView()
                .controlSize(.small)
            Text("Checking your session…")
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
            Button("Try again", action: onRetry)
                .textButton()
        }
        .padding(.vertical, 56)
        .padding(.horizontal, Theme.Space.xl)
        .frame(maxWidth: .infinity)
    }

    private var configurationNeeded: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Sign-in isn’t configured yet")
                .font(Typography.headline)
                .tracked(Typography.headlineTracking)
                .foregroundStyle(Theme.textPrimary)
            Text("This build has no Clerk publishable key, so there is no sign-in to show. Set `ClerkPublishableKey` in Resources/Info.plist (or the `CLERK_PUBLISHABLE_KEY` environment variable) to a `pk_test_…` / `pk_live_…` key from the Clerk dashboard, then relaunch.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: onRetry)
                .outlinedButton()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    /// The two things a locked window owes the person looking at it: what it does
    /// with their voice, and how to get out of it.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Rectangle()
                .fill(Theme.lineSoft)
                .frame(height: 1)

            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                Text("Audio never leaves this Mac")
                    .monoLabel()
                Spacer(minLength: Theme.Space.sm)
                Text("⌘Q to quit")
                    .monoLabel()
            }
            .foregroundStyle(Theme.textTertiary)

            Text("Your licence is read from this account — there’s no key to paste.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
