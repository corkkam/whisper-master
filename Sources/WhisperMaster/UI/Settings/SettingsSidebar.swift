import SwiftUI

/// The settings window's left rail: brand, section navigation, and a live status
/// footer. Extracted from the shell so it stays focused and is reusable.
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    let state: AppState
    /// Whether both required permissions are granted (drives the status dot).
    let permissionsReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 20)
                .padding(.top, 34)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    navRow(section)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 28)

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.stroke).frame(width: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            BrandLogo(size: 34, cornerRadius: 9)
            Text("Whisper Master")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func navRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                Text(section.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Color.clear)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                StatusDot(color: statusColor)
                Text(statusLabel)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("v\(AppInfo.version) · \(state.hotkey.compactName) to dictate")
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .recording, .preparingModels, .failed:
            return Theme.accent
        case .idle, .stopping:
            return permissionsReady ? Theme.success : Theme.textTertiary
        }
    }

    private var statusLabel: String {
        switch state.phase {
        case .recording: return "Recording"
        case .preparingModels: return "Preparing"
        case .stopping: return "Finalizing"
        case .failed: return "Error"
        case .idle:
            return permissionsReady ? "Ready" : "Needs setup"
        }
    }
}
