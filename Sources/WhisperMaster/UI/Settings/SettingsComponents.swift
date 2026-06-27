import SwiftUI

// Daylight building blocks: rows separated by hairlines (no heavy cards), with a
// subtle boxed variant reserved for tiles and the words field.

/// A group of settings rows. Default is an airy hairline group (a rule top and
/// bottom, no fill). Pass `boxed: true` for the few elements that want a panel
/// (stat tiles, the words field, the engine row).
struct SettingsCard<Content: View>: View {
    var boxed: Bool = false
    var contentPadding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(contentPadding)
            .modifier(GroupChrome(boxed: boxed))
    }
}

private struct GroupChrome: ViewModifier {
    let boxed: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if boxed {
            content
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
        } else {
            content
                .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
        }
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
        .padding(.vertical, 17)
    }
}

/// Full-width hairline between rows.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }
}

/// Uppercased group heading shown above a group.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Typography.label)
            .tracking(1.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Accent kicker above a section title.
struct KickerLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Typography.kicker)
            .tracking(2.2)
            .foregroundStyle(Theme.accent)
    }
}

/// Light pill toggle. Off is warm sand, on is the vermillion accent.
struct ThemeToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accent : Theme.surfaceSunken)
                    .frame(width: 44, height: 26)
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
    }
}

/// Small status dot.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
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
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.85 : 1))
            )
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
                    .fill(configuration.isPressed ? Theme.surfaceSunken : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}
