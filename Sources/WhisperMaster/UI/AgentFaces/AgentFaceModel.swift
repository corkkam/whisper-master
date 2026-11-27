import Foundation

// The agent faces, as data. Pure: no SwiftUI, no AppKit, so every rule below is
// pinned by `AgentFaceTests`. A face shows only a state the harness emitted; no
// model and no prompt text decides an expression.
//
// Two channels never mix. **Identity** is the silhouette, the hue, the name and
// the role badge. **State** is the ring, the eyes, the brows and the orb figure.
// Amber, green, red and grey are reserved for states, so no identity hue uses them.

// MARK: - State

enum AgentFaceState: String, CaseIterable, Codable, Sendable {
    case idle, listening, thinking, discussing, working, waiting, done, error, overBudget, asleep

    /// The state in words: the VoiceOver value and the hover label.
    var words: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .discussing: return "Discussing"
        case .working: return "Working"
        case .waiting: return "Waiting for approval"
        case .done: return "Done"
        case .error: return "Error, needs you"
        case .overBudget: return "Over budget"
        case .asleep: return "Asleep"
        }
    }

    /// Rail order after the lead. Lower comes first.
    var railRank: Int {
        switch self {
        case .waiting: return 0
        case .error: return 1
        case .working: return 2
        case .discussing: return 3
        case .thinking: return 4
        case .listening: return 5
        case .done: return 6
        case .idle: return 7
        case .overBudget: return 8
        case .asleep: return 9
        }
    }
}

// MARK: - Role

enum AgentFaceSilhouette: String, Sendable {
    case circle, roundedSquare, hexagon
}

enum AgentFaceRole: String, CaseIterable, Codable, Sendable {
    case lead, pm, qa, design, marketing, user, architect, component

    /// The role badge. A component agent shows the first two letters of its
    /// component instead (`AgentFaceIdentity.badge`).
    var badge: String {
        switch self {
        case .lead: return "LD"
        case .pm: return "PM"
        case .qa: return "QA"
        case .design: return "PD"
        case .marketing: return "MK"
        case .user: return "US"
        case .architect: return "AR"
        case .component: return "CO"
        }
    }

    var words: String {
        switch self {
        case .lead: return "lead agent"
        case .pm: return "project manager"
        case .qa: return "quality assurance"
        case .design: return "product designer"
        case .marketing: return "marketing"
        case .user: return "user persona"
        case .architect: return "architect"
        case .component: return "component agent"
        }
    }

    /// Lead: circle. Component agent: rounded square. Persona: hexagon.
    var silhouette: AgentFaceSilhouette {
        switch self {
        case .lead: return .circle
        case .component: return .roundedSquare
        case .pm, .qa, .design, .marketing, .user, .architect: return .hexagon
        }
    }
}

// MARK: - Identity hue

/// One identity hue, as numbers so the reserved-colour rule is testable. The
/// view turns it into a colour for each ground (`Theme.AgentFace`).
struct AgentFaceHue: Hashable, Sendable {
    /// 0 to 360.
    var degrees: Double
    /// 0 to 1.
    var saturation: Double

    /// Six hues in the blue, violet and teal range. Index order is load-bearing:
    /// a stored `hueIndex` points into it. Append, never reorder.
    static let palette: [AgentFaceHue] = [
        AgentFaceHue(degrees: 212, saturation: 0.72),  // azure
        AgentFaceHue(degrees: 232, saturation: 0.62),  // blue
        AgentFaceHue(degrees: 252, saturation: 0.55),  // indigo
        AgentFaceHue(degrees: 270, saturation: 0.52),  // violet
        AgentFaceHue(degrees: 290, saturation: 0.45),  // purple
        AgentFaceHue(degrees: 192, saturation: 0.70),  // teal
    ]

    /// The hues the state rings own: red (error), amber (waiting), green (done).
    /// Grey (over budget) is owned by low saturation.
    static let reservedDegrees: [Double] = [0, 40, 140]
    static let minimumReservedDistance: Double = 30
    static let minimumSaturation: Double = 0.35

    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    var avoidsReservedStateColors: Bool {
        saturation >= Self.minimumSaturation
            && Self.reservedDegrees.allSatisfy {
                Self.angularDistance(degrees, $0) >= Self.minimumReservedDistance
            }
    }
}

/// FNV-1a over UTF-8. `String.hashValue` is seeded per process, so it cannot
/// give a hue or a blink rhythm that stays the same across launches.
enum AgentFaceHash {
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - Identity

struct AgentFaceIdentity: Hashable, Sendable {
    var name: String
    var role: AgentFaceRole
    var hueIndex: Int
    var componentName: String?
    /// Set only when this agent runs on a different model, for the small mark.
    var harness: AgentHarness?

    init(
        name: String, role: AgentFaceRole, hueIndex: Int? = nil,
        componentName: String? = nil, harness: AgentHarness? = nil
    ) {
        self.name = name
        self.role = role
        self.hueIndex = hueIndex ?? Self.defaultHueIndex(for: name)
        self.componentName = componentName
        self.harness = harness
    }

    static func defaultHueIndex(for name: String) -> Int {
        Int(AgentFaceHash.fnv1a(name) % UInt64(AgentFaceHue.palette.count))
    }

    var hue: AgentFaceHue {
        let n = AgentFaceHue.palette.count
        return AgentFaceHue.palette[((hueIndex % n) + n) % n]
    }

    var badge: String {
        guard role == .component, let component = componentName else { return role.badge }
        let letters = component.filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? role.badge : String(letters.prefix(2)).uppercased()
    }

    var roleWords: String {
        guard role == .component, let component = componentName, !component.isEmpty else {
            return role.words
        }
        return "\(component) component agent"
    }

    /// The on-screen name: 8 characters at most. The full name is in the hover
    /// label and VoiceOver.
    var shortName: String {
        name.count <= 8 ? name : String(name.prefix(7)) + "\u{2026}"
    }

    var accessibilityLabel: String { "\(name), \(roleWords)" }

    /// 6 to 10 s, from the name, so two idle faces do not blink together and
    /// one face keeps its rhythm across launches.
    var blinkInterval: TimeInterval {
        6 + Double(AgentFaceHash.fnv1a(name) % 4001) / 1000
    }
}

// MARK: - Look

/// The pure description of one state: everything the view needs to draw it.
struct AgentFaceLook: Equatable, Sendable {
    enum Eyes: Equatable, Sendable { case open, wide, flat, halfClosed, closed, happyArcs }
    enum Gaze: Equatable, Sendable { case center, upLeft, side, down, towardScreenCentre }
    /// `worried` lifts the inner ends; `slanted` lowers them.
    enum Brows: Equatable, Sendable { case level, raised, worried, slanted, low }
    enum Ring: Equatable, Sendable { case none, identity, waiting, done, error, budget }
    enum Badge: Equatable, Sendable {
        case none, alert, budget
        var text: String? {
            switch self {
            case .none: return nil
            case .alert: return "!"
            case .budget: return "$"
            }
        }
    }
    struct Pulse: Equatable, Sendable {
        var period: TimeInterval
        var window: TimeInterval
    }

    var orb: OrbState
    /// `nil` is the figure's own wave; `0` is a calm, perfect sphere.
    var orbGain: Double?
    /// The figure runs (only on a hero face, and never under reduced motion).
    var moving: Bool
    /// 1 is the full orb; below 1 the dots pull in (`ThinkingOrb.gather`).
    var gather: Double
    var dotOpacity: Double
    var desaturated: Bool
    var eyes: Eyes
    /// The eyes become `.open` this long after the state starts. `nil` holds them.
    var eyesSettleAfter: TimeInterval?
    var gaze: Gaze
    var brows: Brows
    var ring: Ring
    /// The ring fades out this long after the state starts. `nil` holds it.
    var ringFadesAfter: TimeInterval?
    var badge: Badge
    var pulse: Pulse?
    var blinks: Bool
    /// Shows the short tool word under the name.
    var showsDetail: Bool
    var accessibilityValue: String

    var ringAnimates: Bool { pulse != nil || ringFadesAfter != nil }

    static func look(for state: AgentFaceState, reduceMotion: Bool) -> AgentFaceLook {
        var l = AgentFaceLook(
            orb: .listening, orbGain: 0, moving: false, gather: 1, dotOpacity: 1,
            desaturated: false, eyes: .open, eyesSettleAfter: nil, gaze: .center,
            brows: .level, ring: .none, ringFadesAfter: nil, badge: .none, pulse: nil,
            blinks: false, showsDetail: false, accessibilityValue: state.words)
        switch state {
        case .idle:
            l.blinks = true
        case .listening:
            l.orb = .listening; l.orbGain = nil; l.moving = true
            l.eyes = .wide; l.brows = .raised; l.ring = .identity
        case .thinking:
            l.orb = .solving; l.orbGain = nil; l.moving = true
            l.gaze = .upLeft; l.ring = .identity
        case .discussing:
            l.orb = .composing; l.orbGain = nil; l.moving = true
            l.gaze = .side; l.ring = .identity
        case .working:
            l.orb = .working; l.orbGain = nil; l.moving = true
            l.gaze = .down; l.ring = .identity; l.showsDetail = true
        case .waiting:
            l.gaze = .towardScreenCentre; l.brows = .worried; l.ring = .waiting
            l.pulse = Pulse(period: 2, window: 10)
        case .done:
            l.gather = 0.74; l.eyes = .happyArcs; l.eyesSettleAfter = 1.2
            l.brows = .raised; l.ring = .done; l.ringFadesAfter = 8
        case .error:
            l.eyes = .flat; l.brows = .slanted; l.ring = .error; l.badge = .alert
        case .overBudget:
            l.orb = .shaping; l.orbGain = nil; l.desaturated = true; l.dotOpacity = 0.7
            l.eyes = .halfClosed; l.brows = .low; l.ring = .budget; l.badge = .budget
        case .asleep:
            l.dotOpacity = 0.4; l.gather = 0.9; l.eyes = .closed
        }
        if reduceMotion {
            // One still frame per state: no figure, no blink, no pulse, and the
            // finished face holds its arcs and ring instead of changing later.
            l.moving = false; l.blinks = false; l.pulse = nil
            l.eyesSettleAfter = nil; l.ringFadesAfter = nil
        }
        return l
    }
}

// MARK: - Time

/// What one instant of a face looks like. A pure function of time, so the
/// snapshot renderer and the tests can draw any instant.
struct AgentFaceFrame: Equatable, Sendable {
    var eyes: AgentFaceLook.Eyes
    var ringOpacity: Double
    /// 0 to 1: the soft halo of the waiting pulse.
    var pulse: Double
    var gather: Double
}

enum AgentFaceMotion {
    static let frameInterval: TimeInterval = 1.0 / 30.0
    static let blinkDuration: TimeInterval = 0.15
    static let ringFadeDuration: TimeInterval = 0.4
    static let clearDuration: TimeInterval = 0.6

    static func frame(
        _ look: AgentFaceLook, blinkInterval: TimeInterval,
        since: Date?, clearedAt: Date?, at now: Date
    ) -> AgentFaceFrame {
        // No start time means the state is long settled.
        let elapsed = since.map { now.timeIntervalSince($0) } ?? .infinity
        var eyes = look.eyes
        if let settle = look.eyesSettleAfter, elapsed >= settle { eyes = .open }

        var ring = look.ring == .none ? 0.0 : 1.0
        if let fade = look.ringFadesAfter, elapsed > fade {
            ring = max(0, 1 - (elapsed - fade) / ringFadeDuration)
        }

        var pulse = 0.0
        if let p = look.pulse, elapsed >= 0, elapsed < p.window {
            pulse = 0.5 - 0.5 * cos(2 * .pi * elapsed / p.period)
        }

        var gather = look.gather
        if let clearedAt {
            let c = now.timeIntervalSince(clearedAt)
            if c >= 0, c < clearDuration {
                // The dots pull into the centre and spread out again, once.
                gather *= 1 - 0.85 * sin(.pi * c / clearDuration)
                // The one blink sits at the bottom of the gather.
                let mid = clearDuration / 2
                if abs(c - mid) < blinkDuration / 2, eyes != .closed { eyes = .closed }
            }
        }

        if look.blinks, let since, isBlinking(anchor: since, interval: blinkInterval, at: now) {
            eyes = .closed
        }
        return AgentFaceFrame(eyes: eyes, ringOpacity: ring, pulse: pulse, gather: gather)
    }

    /// A blink starts each `interval` after `anchor` (not at it) and lasts 150 ms.
    static func isBlinking(anchor: Date, interval: TimeInterval, at now: Date) -> Bool {
        let e = now.timeIntervalSince(anchor)
        guard e >= interval else { return false }
        return e.truncatingRemainder(dividingBy: interval) < blinkDuration
    }

    /// The redraws a face needs when its figure is not running: dense windows
    /// (pulse, ring fade, context clear) only for a hero, single marks for
    /// everyone, and the sparse blink. An empty plan means no timeline at all.
    static func plan(
        _ look: AgentFaceLook, blinkInterval: TimeInterval,
        since: Date?, clearedAt: Date?, hero: Bool
    ) -> AgentFaceSchedulePlan {
        var plan = AgentFaceSchedulePlan()
        if let since {
            if let p = look.pulse, hero {
                plan.dense.append(since...since.addingTimeInterval(p.window))
            }
            if let settle = look.eyesSettleAfter {
                plan.marks.append(since.addingTimeInterval(settle))
            }
            if let fade = look.ringFadesAfter {
                let start = since.addingTimeInterval(fade)
                if hero {
                    plan.dense.append(start...start.addingTimeInterval(ringFadeDuration))
                } else {
                    plan.marks.append(start.addingTimeInterval(ringFadeDuration))
                }
            }
            if look.blinks { plan.blink = .init(anchor: since, interval: blinkInterval) }
        }
        if let clearedAt {
            plan.dense.append(clearedAt...clearedAt.addingTimeInterval(clearDuration))
        }
        return plan
    }
}

/// The redraw dates of a face whose figure is still. The view wraps it in a
/// `TimelineSchedule`; it ends when nothing is left, so the timeline stops.
struct AgentFaceSchedulePlan: Equatable, Sendable {
    struct Blink: Equatable, Sendable { var anchor: Date; var interval: TimeInterval }

    var dense: [ClosedRange<Date>] = []
    var marks: [Date] = []
    var blink: Blink?

    var isEmpty: Bool { dense.isEmpty && marks.isEmpty && blink == nil }

    func next(after d: Date) -> Date? {
        var candidates: [Date] = []
        for w in dense {
            if d < w.lowerBound {
                candidates.append(w.lowerBound)
            } else if d < w.upperBound {
                candidates.append(min(d.addingTimeInterval(AgentFaceMotion.frameInterval), w.upperBound))
            }
        }
        if let m = marks.filter({ $0 > d }).min() { candidates.append(m) }
        if let b = blink, b.interval > 0 {
            let k = max(1, (d.timeIntervalSince(b.anchor) / b.interval).rounded(.down))
            let start = b.anchor.addingTimeInterval(k * b.interval)
            for date in [start, start.addingTimeInterval(AgentFaceMotion.blinkDuration),
                         start.addingTimeInterval(b.interval)] where date > d {
                candidates.append(date)
            }
        }
        return candidates.min()
    }
}

// MARK: - Rail

struct AgentRailItem: Identifiable, Hashable, Sendable {
    var id: String
    var identity: AgentFaceIdentity
    var state: AgentFaceState
    /// A short tool word for the working chip, e.g. "tests". Never a tool id.
    var detail: String?
    /// Faces with the same group id are linked by a dotted line on the rail.
    var discussionGroup: String?
    /// When `state` started. `AgentRailPanel` stamps it on a change when the
    /// caller leaves it nil.
    var since: Date?
    /// When this agent last cleared its context: one scatter-and-gather.
    var contextClearedAt: Date?

    init(
        id: String, identity: AgentFaceIdentity, state: AgentFaceState,
        detail: String? = nil, discussionGroup: String? = nil,
        since: Date? = nil, contextClearedAt: Date? = nil
    ) {
        self.id = id
        self.identity = identity
        self.state = state
        self.detail = detail
        self.discussionGroup = discussionGroup
        self.since = since
        self.contextClearedAt = contextClearedAt
    }

    /// The last part of the project folder, from the id (project + "/" + agent).
    var projectName: String {
        guard let slash = id.lastIndex(of: "/") else { return "" }
        return AgentSession.repoName(fromPath: String(id[..<slash]))
    }

    var hoverText: String {
        var text = "\(identity.name) \u{00B7} \(identity.roleWords.capitalizedFirst) \u{00B7} \(state.words)"
        if state == .working, let detail, !detail.isEmpty { text += ", \(detail)" }
        return text
    }

    var accessibilityValue: String {
        guard state == .working, let detail, !detail.isEmpty else { return state.words }
        return "\(state.words), \(detail)"
    }
}

enum AgentRail {
    static let maxVisible = 5
    static let maxHeroes = 2

    /// Lead first, then by `AgentFaceState.railRank`; ties keep the input order.
    static func ordered(_ items: [AgentRailItem]) -> [AgentRailItem] {
        items.enumerated().sorted { a, b in
            let la = a.element.identity.role == .lead, lb = b.element.identity.role == .lead
            if la != lb { return la }
            if a.element.state.railRank != b.element.state.railRank {
                return a.element.state.railRank < b.element.state.railRank
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// At most two faces animate: the ones that need a person first, then the
    /// lead, then rail order. Only states with a running figure or a pulse count.
    static func heroes(_ items: [AgentRailItem]) -> Set<String> {
        let animating = items.filter {
            let look = AgentFaceLook.look(for: $0.state, reduceMotion: false)
            return look.moving || look.pulse != nil
        }
        let ranked = animating.enumerated().sorted { a, b in
            func tier(_ i: AgentRailItem) -> Int {
                if i.state == .waiting { return 0 }
                return i.identity.role == .lead ? 1 : 2
            }
            let ta = tier(a.element), tb = tier(b.element)
            return ta != tb ? ta < tb : a.offset < b.offset
        }
        return Set(ranked.prefix(maxHeroes).map(\.element.id))
    }

    static func capped(_ items: [AgentRailItem], limit: Int = maxVisible) -> (visible: [AgentRailItem], overflow: Int) {
        (Array(items.prefix(limit)), max(0, items.count - limit))
    }

    /// Pairs of visible indices to link: consecutive members of each group.
    static func discussionLinks(_ visible: [AgentRailItem]) -> [(Int, Int)] {
        var last: [String: Int] = [:]
        var links: [(Int, Int)] = []
        for (i, item) in visible.enumerated() {
            guard let g = item.discussionGroup else { continue }
            if let prev = last[g] { links.append((prev, i)) }
            last[g] = i
        }
        return links
    }

    static func activeCount(_ items: [AgentRailItem]) -> Int {
        items.filter { $0.state != .asleep }.count
    }

    static func accessibilityLabel(_ items: [AgentRailItem]) -> String {
        "Agent team, \(activeCount(items)) active"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
