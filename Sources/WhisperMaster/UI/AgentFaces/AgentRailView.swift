import SwiftUI

/// The team, as a narrow vertical rail at the right edge of the screen: the lead
/// first, at most five faces, then "+N". Faces in one discussion are linked by a
/// thin dotted line. The hover label sits to the left of the rail, in the
/// panel's transparent area, so the rail itself stays 56 pt wide.
///
/// The view takes plain values. `AgentRailPanel` decides which face the pointer
/// is on (`hoveredID`), because the panel is click-through except on a face and
/// SwiftUI's own hover tracking does not see a pointer it does not receive.
struct AgentRailView: View {
    let items: [AgentRailItem]
    var reducedMotion: Bool = false
    var hoveredID: String? = nil
    /// Draw this instant (the snapshot renderer).
    var now: Date? = nil
    var onSelect: (String) -> Void = { _ in }
    /// Each face's frame in the `AgentRailView.space` coordinate space.
    var onFaceFrames: ([String: CGRect]) -> Void = { _ in }

    static let width: CGFloat = 56
    static let faceSize: CGFloat = 36
    static let leadFaceSize: CGFloat = 44
    /// Room for the hover label to the left of the rail.
    static let labelRoom: CGFloat = 240
    static let space = "AgentRailPanel"

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        let ordered = AgentRail.ordered(items)
        let (visible, overflow) = AgentRail.capped(ordered)
        let heroes = AgentRail.heroes(visible)
        let links = AgentRail.discussionLinks(visible)

        VStack(spacing: Theme.Space.sm) {
            ForEach(visible) { item in
                cell(item, hero: heroes.contains(item.id))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(Typography.sans(11, .semibold))
                    .foregroundStyle(Theme.AgentFace.secondaryInk(dark: dark))
                    .frame(minWidth: 28, minHeight: 24)
                    .accessibilityLabel("\(overflow) more agents")
            }
        }
        .padding(.vertical, Theme.Space.md)
        .frame(width: Self.width)
        .backgroundPreferenceValue(FaceAnchorKey.self) { anchors in
            GeometryReader { proxy in
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    if let a = anchors[visible[link.0].id], let b = anchors[visible[link.1].id] {
                        DiscussionLink(from: proxy[a], to: proxy[b])
                            .stroke(Theme.AgentFace.secondaryInk(dark: dark).opacity(0.7),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.5, 4]))
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Self.width / 2, style: .continuous)
                .fill(Theme.AgentFace.railFill(dark: dark))
                .overlay(RoundedRectangle(cornerRadius: Self.width / 2, style: .continuous)
                    .stroke(Theme.AgentFace.railBorder(dark: dark), lineWidth: 1)))
        .onPreferenceChange(FaceFrameKey.self) { onFaceFrames($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AgentRail.accessibilityLabel(items))
    }

    private func cell(_ item: AgentRailItem, hero: Bool) -> some View {
        let size = item.identity.role == .lead ? Self.leadFaceSize : Self.faceSize
        let look = AgentFaceLook.look(for: item.state, reduceMotion: reducedMotion)
        return VStack(spacing: 3) {
            AgentFaceView(
                identity: item.identity, state: item.state, size: size, hero: hero,
                reducedMotion: reducedMotion, since: item.since,
                contextClearedAt: item.contextClearedAt, now: now)
                .anchorPreference(key: FaceAnchorKey.self, value: .bounds) { [item.id: $0] }
            Text(item.identity.shortName)
                .font(Typography.sans(11, .medium))
                .foregroundStyle(Theme.AgentFace.secondaryInk(dark: dark))
                .lineLimit(1)
                .fixedSize()
            if look.showsDetail, let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(Typography.sans(11, .medium))
                    .foregroundStyle(Theme.AgentFace.identity(item.identity.hue, dark: dark))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(
                        Theme.AgentFace.identity(item.identity.hue, dark: dark).opacity(0.14)))
                    .frame(maxWidth: Self.width - 4)
            }
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear.preference(key: FaceFrameKey.self, value: [item.id: g.frame(in: .named(Self.space))])
        })
        .overlay(alignment: .leading) {
            // A zero-width anchor at the cell's leading edge; the label hangs to its left.
            Color.clear.frame(width: 0).overlay(alignment: .trailing) {
                if hoveredID == item.id { hoverLabel(item).padding(.trailing, Theme.Space.xs) }
            }
        }
        .onTapGesture { onSelect(item.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.identity.accessibilityLabel)
        .accessibilityValue(item.accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect(item.id) }
    }

    private func hoverLabel(_ item: AgentRailItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.identity.name)
                .font(Typography.sans(12, .semibold))
                .foregroundStyle(Theme.AgentFace.ink(dark: dark))
            Text("\(item.identity.roleWords.prefix(1).uppercased())\(item.identity.roleWords.dropFirst()) \u{00B7} \(item.accessibilityValue)")
                .font(Typography.sans(11))
                .foregroundStyle(Theme.AgentFace.secondaryInk(dark: dark))
        }
        .lineLimit(1)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xs + 1)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.AgentFace.railFill(dark: dark)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Theme.AgentFace.railBorder(dark: dark), lineWidth: 1))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// The dotted link between two faces in one discussion: a soft bow to the left
/// of the rail, so it never runs through the faces or the names between them.
private struct DiscussionLink: Shape {
    let from: CGRect
    let to: CGRect

    func path(in rect: CGRect) -> Path {
        let a = CGPoint(x: from.minX - 2, y: from.midY)
        let b = CGPoint(x: to.minX - 2, y: to.midY)
        let bow = min(a.x, b.x) - 6
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: bow, y: a.y), control2: CGPoint(x: bow, y: b.y))
        return p
    }
}

private struct FaceAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct FaceFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
