import AppKit
import SwiftUI

/// The download / setup prompt shown when the voice engine isn't installed yet,
/// or while it's downloading, or after a setup failure. Shared by every section
/// (via the settings shell) except the Engine section, which has its own status.
struct SetupBanner: View {
    @Bindable var state: AppState
    let startSetup: () -> Void
    let cancelSetup: () -> Void
    let openEngine: () -> Void

    private var preparing: Bool { state.preparingEngine == state.selectedEngine }
    private var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }
    private var percent: Int { Int((state.download?.fractionCompleted ?? 0) * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 42, height: 42)
                    if preparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subhead)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if preparing {
                    Text("\(percent)%")
                        .font(Typography.sans(20, .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }
            }

            if preparing {
                ProgressView(value: state.download?.fractionCompleted ?? 0)
                    .tint(Theme.accent)
            }

            HStack {
                if preparing {
                    SecondaryButton(title: "Cancel", action: cancelSetup)
                } else {
                    PrimaryButton(title: "Download voice engine", icon: "arrow.down.circle", action: startSetup)
                    SecondaryButton(title: "Open engine", action: openEngine)
                }
                Spacer()
                Text(state.selectedEngine.estimatedDownloadSize)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1.5)
        )
    }

    private var headline: String {
        if case .failed = state.phase, !state.selectedEngine.isInstalled {
            return "Couldn't finish setup"
        }
        if preparing {
            return state.selectedEngine.isInstalled
                ? "Loading \(state.selectedEngine.displayName) engine…"
                : "Downloading \(state.selectedEngine.displayName) engine…"
        }
        return "Voice engine not installed"
    }

    private var subhead: String {
        if case .failed(let msg) = state.phase, !state.selectedEngine.isInstalled {
            return msg
        }
        if preparing {
            return state.download?.detail ?? "Preparing on-device model. This only happens once."
        }
        return "One-time download of the on-device model. Whisper Master can't transcribe until this finishes."
    }
}
