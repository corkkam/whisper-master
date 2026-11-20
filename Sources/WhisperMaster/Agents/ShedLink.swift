import AppKit
import Foundation

/// The single place a Shed session is opened for the user: the Coding tab of the main
/// window, on that session. Callers never build the URL.
enum ShedLink {
    /// Brings up the main window on the Coding tab. Set by the AppDelegate, which owns
    /// the window.
    @MainActor static var showCodingTab: () -> Void = {}

    /// Replaceable, and swapped by tests.
    @MainActor static var open: (_ sessionID: String, _ endpoint: ShedEndpoint?) -> Void = { id, endpoint in
        ShedPage.shared.show(sessionID: id, endpoint: endpoint)
        showCodingTab()
    }

    @MainActor
    static func openSession(id: String, endpoint: ShedEndpoint?) {
        open(id, endpoint)
    }
}
