import SwiftUI

/// A Shed agent mid-turn, in the menu-bar row: the harness glyph in the leading wing
/// and the working orb in the trailing wing. No text, so it stays a slim ambient row.
///
/// Click-through on purpose (`DictationPillContent` does not count it as interactive),
/// so the pointer can rest on the notch and open the hover panel that lists each agent.
struct NotchShedWorkingRow: View {
    let harnesses: [AgentHarness]
    var orbSize: CGFloat = NotchTranscriptRow.orbDiameter
    var verticalInset: CGFloat = NotchTranscriptRow.verticalPadding

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            ForEach(harnesses, id: \.self) { HarnessGlyph(harness: $0, size: orbSize * 0.55) }
            Spacer(minLength: Theme.Space.sm)
            OrbView(level: 0, mode: .working, diameter: orbSize, preset: .small)
                .frame(width: orbSize, height: orbSize)
        }
        .padding(.horizontal, NotchTranscriptRow.horizontalPadding)
        .padding(.vertical, verticalInset)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(harnesses.map(\.displayName).joined(separator: " and ")) working")
    }
}

/// A plain text glyph for a harness, not a brand mark (see `AgentHarness.glyph`).
struct HarnessGlyph: View {
    let harness: AgentHarness
    var size: CGFloat = 14

    var body: some View {
        Text(harness.glyph)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.Notch.text)
            .accessibilityLabel(harness.displayName)
    }
}
