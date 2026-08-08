import Foundation

/// A parsed `CFBundleShortVersionString`, ordered the way a human reads it.
///
/// The whole "What's New" gate rests on this: a **string** comparison puts
/// "1.10.0" *below* "1.9.0" (because "1" < "9" at the third character), so an
/// upgrade would silently show nothing for every release past `.9`. Versions are
/// therefore compared component-wise, numerically.
///
/// Pre-release markers matter here too — non-stable channels are required to
/// carry one (`1.3.0-beta.2`, `1.3.0-dev.1`, see the release rules in
/// `CLAUDE.md`) — and semver's own precedence rule is the right one: a
/// pre-release sorts *below* the release it leads to, so a beta tester moving
/// from `1.3.0-beta.2` to `1.3.0` is an upgrade, and the reverse is not.
struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers: `["beta", "2"]` for `1.3.0-beta.2`.
    /// Empty for a stable release.
    let prerelease: [String]

    /// Parses `major[.minor[.patch]][-prerelease][+build]`, tolerating a leading
    /// `v`. Returns `nil` for anything that isn't a version — including
    /// `AppInfo.version`'s "—" placeholder, which is what a bundle-less
    /// `swift build` / test run reports.
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        // Build metadata is ignored for precedence, per semver.
        if let plus = text.firstIndex(of: "+") { text = String(text[text.startIndex..<plus]) }

        let core: String
        if let dash = text.firstIndex(of: "-") {
            core = String(text[text.startIndex..<dash])
            let tail = text[text.index(after: dash)...]
            prerelease = tail.split(separator: ".").map(String.init)
        } else {
            core = text
            prerelease = []
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        major = numbers[0] ?? 0
        minor = numbers.count > 1 ? (numbers[1] ?? 0) : 0
        patch = numbers.count > 2 ? (numbers[2] ?? 0) : 0
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = [lhs.major, lhs.minor, lhs.patch]
        let right = [rhs.major, rhs.minor, rhs.patch]
        for (a, b) in zip(left, right) where a != b { return a < b }
        return comparePrerelease(lhs.prerelease, rhs.prerelease)
    }

    /// Semver §11.4: a version *with* a pre-release ranks below the same core
    /// version without one; otherwise identifiers are compared left to right,
    /// numerically where both are numeric, and a numeric identifier always ranks
    /// below an alphanumeric one.
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return !lhs.isEmpty && rhs.isEmpty }
        for (a, b) in zip(lhs, rhs) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }
        return lhs.count < rhs.count
    }
}
