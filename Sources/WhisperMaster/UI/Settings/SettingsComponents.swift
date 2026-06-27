import SwiftUI

// Reusable building blocks for the settings UI.

/// A grouped surface card with a faint top highlight + soft shadow for depth.
/// Pass `contentPadding` for free-form content; leave it 0 when filling with
/// `SettingsRow`s (they carry their own insets).
struct SettingsCard<Content: View>: View {
    var contentPadding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(contentPadding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.topHighlight, Theme.stroke],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
    }
}

/// A labeled row: title (+ optional subtitle) on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

/// Hairline separator between rows, inset to align under the row text.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(height: 1)
            .padding(.leading, 20)
    }
}

/// A small uppercased group heading shown above a card.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Typography.label)
            .tracking(1.4)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A small uppercased accent kicker (used above section titles).
struct KickerLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Typography.kicker)
            .tracking(2)
            .foregroundStyle(Theme.accent)
    }
}

/// A crafted vermillion pill switch built from shapes (no AppKit), so it renders
/// consistently and carries the brand. Behaves like a standard toggle.
struct ThemeToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceElevated))
                    .overlay(
                        Capsule().strokeBorder(isOn ? Color.clear : Theme.strokeStrong, lineWidth: 1)
                    )
                    .frame(width: 46, height: 28)
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isOn)
    }
}

/// A small colored status dot with a soft glow.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 4)
    }
}

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { ButtonLabel(title: title, icon: icon) }
            .buttonStyle(AccentButtonStyle())
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { ButtonLabel(title: title, icon: icon) }
            .buttonStyle(GhostButtonStyle())
    }
}

private struct ButtonLabel: View {
    let title: String
    var icon: String?
    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            }
            Text(title).font(Typography.bodyMedium)
        }
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Theme.accentGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Theme.accentDeep.opacity(0.4), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Theme.surfaceElevated.opacity(configuration.isPressed ? 0.6 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}
