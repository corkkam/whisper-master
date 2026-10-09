import SwiftUI

/// The launch auth gate — a warm, glassy welcome that lets the user put their
/// name in (for the greeting) or continue as a guest. Not a hard wall: the app
/// is local-first, so "Continue without an account" is always available.
struct AuthGateView: View {
    @Bindable var account: AccountStore
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            WarmBackground()
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    BrandLogo(size: 60, cornerRadius: 16)
                    VStack(spacing: 6) {
                        Text("Welcome to Whisper Master")
                            .font(Typography.display(26))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                        Text("On-device dictation that stays on your Mac.")
                            .font(Typography.body)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }

                AccountSignInForm(account: account, onSignedIn: onContinue)
                    .padding(24)
                    .frame(width: 380)
                    .glassCard()
            }
            .padding(40)
        }
        .frame(width: 560, height: 560)
    }
}
