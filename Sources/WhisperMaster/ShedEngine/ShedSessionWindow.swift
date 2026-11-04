import AppKit
import WebKit

/// The in-app window onto Shed's web page, signed in as this Mac.
///
/// Shed accepts its master token as the cookie `laya_auth` only from a direct local
/// request, which is exactly what a web view on 127.0.0.1 is. Through this window the
/// user also reaches Shed's own Settings (agents, critic, accounts, phone access).
/// Two windows would fight over one cookie jar and one page state, so there is one.
@MainActor
final class ShedSessionWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private static var current: ShedSessionWindow?

    private let window: NSWindow
    private let webView: WKWebView

    /// The entry point. `nil` opens the session list, an id opens that session.
    static func open(sessionID: String? = nil) {
        let target = current ?? ShedSessionWindow()
        current = target
        target.show(sessionID: sessionID)
    }

    private override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "Agents"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private func show(sessionID: String?) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard let endpoint = ShedEngineSupervisor.shared.endpoint, let token = endpoint.readToken() else {
            webView.loadHTMLString(Self.unavailablePage(ShedEngineSupervisor.shared.state), baseURL: nil)
            return
        }
        let url = endpoint.pageURL(sessionID: sessionID)
        let cookie = HTTPCookie(properties: [
            .name: "laya_auth", .value: token, .domain: "127.0.0.1", .path: "/",
        ])
        let load: () -> Void = { [webView] in _ = webView.load(URLRequest(url: url)) }
        if let cookie {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie, completionHandler: load)
        } else {
            load()
        }
    }

    private static func unavailablePage(_ state: ShedEngineSupervisor.State) -> String {
        let detail: String
        switch state {
        case .off: detail = "The agent engine is off. Turn it on in Settings, under Coding agents."
        case .installing(let m), .notInstalled(let m), .needsNode(let m): detail = m
        case .starting: detail = "The agent engine is starting. Open this window again in a moment."
        case .failed: detail = "The agent engine is not running. See Settings, under Coding agents."
        case .running: detail = "The engine token is not available yet. Try again in a moment."
        }
        let escaped = detail.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<body style='font:15px -apple-system;margin:48px;color:#888;white-space:pre-wrap'>\(escaped)</body>"
    }

    // Links that leave Shed (docs, Tailscale pages) open in the browser, not in this window.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if action.navigationType == .linkActivated, let url = action.request.url,
            !["127.0.0.1", "localhost"].contains(url.host ?? "") {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // Shed's attach-file button needs the system open panel.
    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}
