import AppKit
import Foundation

/// The single place a Shed session is opened for the user. With the bundled engine
/// running that is the in-app window; a Shed the user runs themselves has no
/// token the window can read, so it opens in the browser. Callers never build the URL.
enum ShedLink {
    /// Replaceable, and swapped by tests.
    @MainActor static var open: (_ sessionID: String, _ endpoint: ShedEndpoint?) -> Void = { id, endpoint in
        if ShedEngineSupervisor.shared.endpoint != nil || endpoint == nil {
            ShedSessionWindow.open(sessionID: id)
        } else if let url = endpoint?.pageURL(sessionID: id) {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openSession(id: String, endpoint: ShedEndpoint?) {
        open(id, endpoint)
    }
}
