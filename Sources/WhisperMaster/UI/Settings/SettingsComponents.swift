import SwiftUI

// Daylight building blocks: settings are grouped into soft, warm cards that lift
// off the white canvas. Rows sit *inside* a card, so any separator reads as a
// grouped-row inset rather than a floating underline.

/// A group of settings rows, rendered as one filled card. `boxed` no longer
/// changes the look (every group is a card now); it only tells the card the
/// content brings its own all-around padding (tiles / the words field) so the
/// card shouldn't add its own horizontal inset.
struct SettingsCard<Content: View>: View {
    var boxed: Bool = false
    var contentPadding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(contentPadding)
            .padding(.horizontal, boxed ? 0 : 22)   // inset rows from the rounded edge
            .card()
    }
}

/// A single dashboard tile: a big number/value with a caption, in card chrome.
/// One primitive for both the Insights KPI tiles and the History stat tiles
/// (they used to be two near-identical helpers with *different* elevation).
struct StatTile<Accessory: View>: View {
    let value: String
    let label: String
    var valueColor: Color = Theme.textPrimary
    var caption: String?
    @ViewBuilder var accessory: Accessory

    init(
        value: String,
        label: String,
        valueColor: Color = Theme.textPrimary,
        caption: String? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.value = value
        self.label = label
        self.valueColor = valueColor
        self.caption = caption
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top) {
                Text(value)
                    .font(Typography.metric)
                    .foregroundStyle(valueColor)
                Spacer(minLength: 0)
                accessory
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                if let caption {
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.xl)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// A small rounded tag/chip (used by the vocabulary editor and inline labels).
struct Chip<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    init(_ text: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(text).font(Typography.caption).foregroundStyle(Theme.textPrimary)
            trailing
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous).fill(Theme.surfaceSunken)
        )
    }
}

/// A quiet square icon button with a proper accessibility label (the History
/// row buttons previously had only a hover-only `.help`, invisible to VoiceOver).
struct IconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ systemName: String, label: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.accessibilityLabel = label
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(role == .destructive ? Theme.danger : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                        .fill(Theme.surfaceSunken.opacity(0.6))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
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
///
/// Pass `label` (the setting name) so VoiceOver announces "<name>, switch, on"
/// instead of a bare "button" — the custom `Button` is swapped for a real
/// `Toggle` in the accessibility tree via `accessibilityRepresentation`.
struct ThemeToggle: View {
    @Binding var isOn: Bool
    var label: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.toggle), value: isOn)
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
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
