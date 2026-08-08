import Foundation

/// Where the manifest comes from. Injected so the gate and the controller can be
/// tested without a network — nothing in `swift test` may reach R2.
protocol WhatsNewFetching: Sendable {
    func fetch() async throws -> WhatsNewManifest
}

/// Pulls `whats-new.json` off the public R2 bucket — the same host the Sparkle
/// appcast and the model archives come from (`Auth/BetaAccess.swift`,
/// `ModelInstall/ModelInstaller.swift`; if that host ever moves, this is a
/// fourth place to change).
///
/// Remote on purpose: the note and its demo video are published *between* app
/// releases, so nothing about this surface ships inside the bundle. Everything
/// here is bounded and best-effort — an ephemeral session (no cookies, no disk
/// cache), short timeouts, and a plain `throw` on anything unexpected, because
/// the caller's answer to a failure is always "show nothing".
struct RemoteWhatsNewFetcher: WhatsNewFetching {
    enum FetchError: Error {
        case badResponse(status: Int)
    }

    static let manifestURL = URL(string: "https://dl.corkkam.com/whats-new.json")

    private let url: URL?
    private let session: URLSession

    init(url: URL? = RemoteWhatsNewFetcher.manifestURL, session: URLSession = RemoteWhatsNewFetcher.makeSession()) {
        self.url = url
        self.session = session
    }

    func fetch() async throws -> WhatsNewManifest {
        guard let url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        // The note changes without the app changing, so a stale cached copy is
        // worse than a round trip.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.badResponse(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(WhatsNewManifest.self, from: data)
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
