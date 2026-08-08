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
                    .font(Typography.metric).tracking(Typography.metricTracking)
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
        }
        // Tone, hover, press, pointer cursor and the tooltip all come from the
        // ladder now. The label stays here because a tooltip is not one.
        .iconButton(tone: role == .destructive ? .destructive : .neutral, tooltip: accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
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
                    .font(Typography.headline).tracking(Typography.headlineTracking)
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

/// Uppercased group heading. Mono + wide tracking: this is the "instrument
/// panel" voice, and it is where most of the system's character comes from for
/// the least effort.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .monoLabel()
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Accent kicker above a section title. Same instrument voice, in ember.
struct KickerLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .monoLabel()
            .foregroundStyle(Theme.accent)
    }
}

/// Pill switch. On is **signal**, not ember — an enabled setting is a settled
/// machine state, and ember is reserved for the user's own live voice. Painting
/// every toggle ember is exactly the "generic accent colour" the design system
/// forbids, and it would leave the Settings page reading as one orange field.
///
/// Pass `label` (the setting name) so VoiceOver announces "<name>, switch, on"
/// instead of a bare "button" — the custom `Button` is swapped for a real
/// `Toggle` in the accessibility tree via `accessibilityRepresentation`.
struct ThemeToggle: View {
    @Binding var isOn: Bool
    var label: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The unlit knob: near-white, so it stays legible as a *knob* against the
    /// sunken track.
    private static let knobOff = Color(hex: 0xffffff)

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accent2Fill : Theme.surfaceSunken)
                    .overlay(Capsule().strokeBorder(isOn ? .clear : Theme.line, lineWidth: 1))
                    .frame(width: 44, height: 26)
                Circle()
                    // On: the near-black tint of signal, sitting on its own fill.
                    // Off: a pale knob on a sunken well — a dark knob reads as on.
                    .fill(isOn ? Theme.accent2On : Self.knobOff)
                    .overlay(Circle().strokeBorder(Theme.line, lineWidth: isOn ? 0 : 1))
                    .frame(width: 20, height: 20)
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.toggle), value: isOn)
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
        .pointerCursor()
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

/// A compact state capsule — a dot plus two or three words — for the trailing edge
/// of a list row.
///
/// This exists because a status rendered as a *third line of grey caption text*
/// (what the connector rows used to do) reads as more prose, not as a state: the
/// eye has to parse a sentence to answer "is this thing working?". A tinted pill
/// answers that at a glance and leaves the row two lines tall. Keep the text to a
/// few words — anything that needs a sentence belongs in an inline alert strip
/// under the row, where it has the width to be read.
struct StatusPill: View {
    let text: String
    var tone: Tone = .neutral

    /// §1: signal (not ember) for a healthy machine state, danger for a broken one,
    /// neutral for "deliberately off" — a paused connector is not a warning.
    enum Tone {
        case positive, neutral, warning, danger

        var ink: Color {
            switch self {
            case .positive: return Theme.accent2
            case .neutral: return Theme.textTertiary
            case .warning: return Theme.warning
            case .danger: return Theme.danger
            }
        }

        var fill: Color {
            switch self {
            case .positive: return Theme.successSoft
            case .neutral: return Theme.surfaceSunken
            case .warning: return Theme.warningSoft
            case .danger: return Theme.dangerSoft
            }
        }

        var dot: Color {
            switch self {
            case .positive: return Theme.success
            case .neutral: return Theme.Neutral.n400
            case .warning: return Theme.warning
            case .danger: return Theme.danger
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: tone.dot, size: 6)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(tone.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(tone.fill))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

/// The screen's one real action. Thin wrapper over `PrimaryButtonStyle` — see
/// `UI/Components/ButtonStyles.swift` for the ladder and when each rung applies.
struct PrimaryButton: View {
    let title: String
    var icon: String?
    var isFullWidth: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { ButtonLabel(title: title, icon: icon) }
            .primaryButton(isFullWidth: isFullWidth)
    }
}

/// A supporting action beside a `PrimaryButton`.
struct SecondaryButton: View {
    let title: String
    var icon: String?
    var isFullWidth: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { ButtonLabel(title: title, icon: icon) }
            .secondaryButton(isFullWidth: isFullWidth)
    }
}

/// The lowest-emphasis rung as a named view: "Skip", "Not now", "Cancel".
struct TextButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) { ButtonLabel(title: title, icon: icon) }
            .textButton()
    }
}

/// An irreversible action — delete, clear, sign out.
struct DestructiveButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) { ButtonLabel(title: title, icon: icon) }
            .destructiveButton()
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

