import SwiftUI

/// The shared layout for every notch banner: an SF Symbol, a bold title line and
/// a quieter subtitle, all on the dark notch surface using the `Theme.Notch`
/// sub-palette + `Typography.notch*` faces (so the banners stop each re-inventing
/// their own magic font sizes and `.white.opacity(...)` literals).
///
/// The icon + text form a single combined accessibility element carrying the
/// banner's spoken label; any `trailing` controls (the Bluetooth banner's button
/// + close) live outside that element so they keep their own VoiceOver actions.
struct NotchBannerRow<Subtitle: View, Trailing: View>: View {
    private let icon: String
    private let title: String
    private let accessibilityText: String
    private let subtitle: Subtitle
    private let trailing: Trailing

    /// Full control: a custom subtitle (e.g. an inline keycap) plus trailing
    /// controls. The string/no-trailing conveniences below cover the common case.
    init(
        icon: String,
        title: String,
        accessibilityText: String,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.accessibilityText = accessibilityText
        self.subtitle = subtitle()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: icon)
                    .font(Typography.notchTitle)
                    .foregroundStyle(Theme.Notch.text.opacity(0.9))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.notchTitle)
                        .foregroundStyle(Theme.Notch.text)

                    subtitle
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.textSecondary)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            // Read the message as one element; trailing controls stay separate.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)

            trailing
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Conveniences

extension NotchBannerRow where Subtitle == Text, Trailing == EmptyView {
    /// A plain two-line banner (icon + title + subtitle), no controls.
    init(icon: String, title: String, subtitle: String) {
        self.init(
            icon: icon,
            title: title,
            accessibilityText: "\(title). \(subtitle)",
            subtitle: { Text(subtitle) },
            trailing: { EmptyView() }
        )
    }
}

extension NotchBannerRow where Trailing == EmptyView {
    /// A banner whose subtitle needs custom inline content (e.g. a ⌘V keycap).
    /// `accessibilityText` supplies the spoken form the custom view can't convey.
    init(
        icon: String,
        title: String,
        accessibilityText: String,
        @ViewBuilder subtitle: () -> Subtitle
    ) {
        self.init(
            icon: icon,
            title: title,
            accessibilityText: accessibilityText,
            subtitle: subtitle,
            trailing: { EmptyView() }
        )
    }
}

extension NotchBannerRow where Subtitle == Text {
    /// A two-line banner with trailing controls (the Bluetooth nudge's
    /// "Use built-in" button + close). The trailing closure supplies its own
    /// leading `Spacer` so the text hugs the left and the controls the right.
    init(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            icon: icon,
            title: title,
            accessibilityText: "\(title). \(subtitle)",
            subtitle: { Text(subtitle) },
            trailing: trailing
        )
    }
}
