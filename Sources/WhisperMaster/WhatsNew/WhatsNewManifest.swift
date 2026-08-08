import Foundation

/// One thing a release did, as a line in the window.
struct WhatsNewHighlight: Decodable, Hashable, Sendable, Identifiable {
    /// Stable enough for `ForEach` — the manifest carries no ids and a release
    /// never repeats a highlight title.
    var id: String { title + body }

    let title: String
    /// Optional in the contract; an empty body renders as a title-only line.
    let body: String
    /// SF Symbol name. `sparkles` when the publisher didn't pick one.
    let systemImage: String

    private enum CodingKeys: String, CodingKey {
        case title, body, systemImage
    }

    init(title: String, body: String = "", systemImage: String = WhatsNewHighlight.defaultSymbol) {
        self.title = title
        self.body = body
        self.systemImage = systemImage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        systemImage = try container.decodeIfPresent(String.self, forKey: .systemImage) ?? Self.defaultSymbol
    }

    static let defaultSymbol = "sparkles"
}

/// The note for a single shipped version.
struct WhatsNewRelease: Decodable, Hashable, Sendable, Identifiable {
    var id: String { version }

    /// The `CFBundleShortVersionString` this note belongs to.
    let version: String
    let headline: String
    let publishedAt: Date?
    /// Streamed, never bundled — the video is published to R2 independently of
    /// the app, so a demo can land without cutting a release.
    let videoURL: URL?
    let posterURL: URL?
    let highlights: [WhatsNewHighlight]
    /// Per-release override of the manifest's `schemaVersion`, so the publish
    /// side can add a release the current app can't render without making the
    /// whole file unreadable. Absent means "the manifest's".
    let schemaVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case version, headline, publishedAt, videoURL, posterURL, highlights, schemaVersion
    }

    init(
        version: String,
        headline: String,
        publishedAt: Date? = nil,
        videoURL: URL? = nil,
        posterURL: URL? = nil,
        highlights: [WhatsNewHighlight] = [],
        schemaVersion: Int? = nil
    ) {
        self.version = version
        self.headline = headline
        self.publishedAt = publishedAt
        self.videoURL = videoURL
        self.posterURL = posterURL
        self.highlights = highlights
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        headline = try container.decode(String.self, forKey: .headline)
        // A wrong-typed optional (a number where a URL string was expected) reads
        // as absent rather than failing the whole release.
        publishedAt = Self.date(try? container.decodeIfPresent(String.self, forKey: .publishedAt))
        videoURL = Self.webURL(try? container.decodeIfPresent(String.self, forKey: .videoURL))
        posterURL = Self.webURL(try? container.decodeIfPresent(String.self, forKey: .posterURL))
        highlights = try container.decodeIfPresent([FailableDecodable<WhatsNewHighlight>].self, forKey: .highlights)?
            .compactMap(\.value) ?? []
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }

    var semanticVersion: SemanticVersion? { SemanticVersion(version) }

    /// Whether the window has a media pane to draw. A note with no video is a
    /// perfectly good note — the highlights carry it.
    var hasVideo: Bool { videoURL != nil }

    /// `true` when this app build understands the release's shape.
    func isSupported(manifestSchemaVersion: Int) -> Bool {
        (schemaVersion ?? manifestSchemaVersion) <= WhatsNewManifest.supportedSchemaVersion
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return iso8601.date(from: string) ?? iso8601WithFraction.date(from: string)
    }

    /// Only `http(s)` survives: the manifest is remote, and anything else here
    /// (a `file://` path, a custom scheme) would be handed straight to AVPlayer.
    private static func webURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        return (scheme == "https" || scheme == "http") ? url : nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// The remote manifest, published next to the Sparkle appcast on the same R2
/// bucket (`https://dl.corkkam.com/whats-new.json`).
///
/// Its shape is a contract with the publish side, so decoding is deliberately
/// forgiving in one direction only: **unknown keys are ignored**, every field
/// but `version`/`headline` is optional, a release stamped with a schema this
/// build doesn't understand is *skipped*, and one malformed entry can't take the
/// rest of the list with it. Anything worse than that throws, and the caller
/// degrades to showing nothing — this surface is a delighter and is never
/// allowed to be the reason something failed.
struct WhatsNewManifest: Decodable, Hashable, Sendable {
    /// The manifest shape this build renders. Bump only alongside a real change
    /// to the contract above.
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    /// Ascending by version; unparseable and unsupported entries are dropped at
    /// decode time, so everything here is renderable.
    let releases: [WhatsNewRelease]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, releases
    }

    init(schemaVersion: Int = WhatsNewManifest.supportedSchemaVersion, releases: [WhatsNewRelease]) {
        self.schemaVersion = schemaVersion
        self.releases = Self.usable(releases, schemaVersion: schemaVersion)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.supportedSchemaVersion
        schemaVersion = schema
        let decoded = try container.decodeIfPresent([FailableDecodable<WhatsNewRelease>].self, forKey: .releases) ?? []
        releases = Self.usable(decoded.compactMap(\.value), schemaVersion: schema)
    }

    /// The note to show on an upgrade: the newest release that landed **after**
    /// the version this machine last saw and is not newer than the one running.
    ///
    /// Newest-in-range rather than an exact match on the running version, so a
    /// user who skips 1.1.0 and installs 1.2.0 still gets a note when only
    /// 1.1.0 published one.
    func release(upgradingTo current: SemanticVersion, from lastSeen: SemanticVersion?) -> WhatsNewRelease? {
        releases.last { release in
            guard let version = release.semanticVersion, version <= current else { return false }
            guard let lastSeen else { return true }
            return version > lastSeen
        }
    }

    /// The note for the manual entry point ("What's new" in About): the newest
    /// one this build is old enough to be about, else simply the newest known.
    func latestRelease(notNewerThan current: SemanticVersion?) -> WhatsNewRelease? {
        guard let current else { return releases.last }
        return releases.last { release in
            guard let version = release.semanticVersion else { return false }
            return version <= current
        } ?? releases.last
    }

    private static func usable(_ releases: [WhatsNewRelease], schemaVersion: Int) -> [WhatsNewRelease] {
        releases
            .compactMap { release -> (SemanticVersion, WhatsNewRelease)? in
                guard
                    let version = release.semanticVersion,
                    release.isSupported(manifestSchemaVersion: schemaVersion)
                else { return nil }
                return (version, release)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}

// MARK: - Decoding helpers

/// Decodes an element, or swallows it. Used for the two arrays where one bad
/// entry must not cost the user the whole surface.
private struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
