import Foundation

/// The one entry point to the "What's New" surface.
///
/// Owns the whole decision — gate, fetch, pick the release, put the window up,
/// record that it was seen — so the caller has two calls and no state:
/// `presentIfNeeded()` at launch (after a Sparkle update has relaunched the app
/// on a newer version), and `present(force: true)` from a menu item.
///
/// Three rules hold it together:
/// - **It never blocks.** Both entry points return immediately; the fetch runs
///   in a detached `Task` off the main thread, and every failure — offline,
///   malformed JSON, no note published for this upgrade — degrades to showing
///   nothing. This is a delighter, never a gate.
/// - **Seen means shown.** `markSeen` happens when the window goes up (or when a
///   first install is being caught up quietly), never on a successful fetch, so
///   a launch on a plane can't silently burn the release.
/// - **The presentation is injectable.** Tests drive the whole flow with a stub
///   fetcher and a capture closure, so none of it needs AppKit or a network.
@MainActor
final class WhatsNewController {
    /// Puts a release on screen. `nil` at the call site means the real window.
    typealias Presenter = (WhatsNewRelease) -> Void

    private let currentVersion: String
    private let store: WhatsNewStore
    private let fetcher: any WhatsNewFetching
    private let presenter: Presenter?

    private var window: WhatsNewWindow?
    private var isResolving = false

    init(
        currentVersion: String = AppInfo.version,
        store: WhatsNewStore = WhatsNewStore(),
        fetcher: any WhatsNewFetching = RemoteWhatsNewFetcher(),
        presenter: Presenter? = nil
    ) {
        self.currentVersion = currentVersion
        self.store = store
        self.fetcher = fetcher
        self.presenter = presenter
    }

    /// The launch path: shows the note for this upgrade, if there is one and the
    /// machine hasn't already seen it. Returns immediately.
    func presentIfNeeded() {
        present(force: false)
    }

    /// `force` skips the version gate entirely — the manual "What's new" entry
    /// point, which has to work on a version the user has already seen.
    func present(force: Bool) {
        Task { await resolveAndPresent(force: force) }
    }

    /// The flow itself, `await`-able so tests are deterministic. Returns the
    /// release that was shown, or `nil` when nothing was.
    @discardableResult
    func resolveAndPresent(force: Bool) async -> WhatsNewRelease? {
        guard !isResolving else { return nil }
        isResolving = true
        defer { isResolving = false }

        let lastSeen = store.lastSeenVersion
        if !force {
            switch WhatsNewGate.decide(currentVersion: currentVersion, lastSeenVersion: lastSeen) {
            case .firstInstall:
                store.markSeen(currentVersion)
                return nil
            case .upToDate:
                return nil
            case .show:
                break
            }
        }

        let manifest: WhatsNewManifest
        do {
            manifest = try await fetcher.fetch()
        } catch {
            Log.app.notice("what's-new manifest unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let release = pick(from: manifest, force: force, lastSeen: lastSeen) else { return nil }
        show(release)
        store.markSeen(currentVersion)
        return release
    }

    /// Closes the window if it's up. The window closes itself on its own button;
    /// this is for the app tearing down around it.
    func close() {
        window?.close()
        window = nil
    }

    private func pick(from manifest: WhatsNewManifest, force: Bool, lastSeen: String?) -> WhatsNewRelease? {
        let current = SemanticVersion(currentVersion)
        if force {
            return manifest.latestRelease(notNewerThan: current)
        }
        guard let current else { return nil }
        return manifest.release(upgradingTo: current, from: lastSeen.flatMap(SemanticVersion.init))
    }

    private func show(_ release: WhatsNewRelease) {
        if let presenter {
            presenter(release)
            return
        }
        // Re-presenting while it's already up just brings it forward, so a
        // double invocation can't stack two windows on one release.
        if let window {
            window.show()
            return
        }
        let window = WhatsNewWindow(release: release) { [weak self] in
            self?.window = nil
        }
        self.window = window
        window.show()
    }
}
