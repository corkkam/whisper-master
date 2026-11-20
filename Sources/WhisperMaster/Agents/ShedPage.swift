import AppKit
import SwiftUI
import WebKit

/// Shed's web page, shown in the main window's Coding tab and signed in as this Mac.
///
/// Shed accepts its master token as the cookie `laya_auth` only from a direct local
/// request, which is exactly what a web view on 127.0.0.1 is. Through this page the
/// user also reaches Shed's own Settings (agents, critic, accounts, phone access).
/// There is one web view for the whole app: two would fight over one cookie jar and one
/// page state, and keeping it alive across tab switches keeps the page where it was.
@MainActor
final class ShedPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = ShedPage()

    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var loadedBase: URL?

    private override init() {
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// `nil` keeps the page where it is (the session list on first load), an id opens
    /// that session. `endpoint` is the Shed the notch reads, so the two always agree.
    func show(sessionID: String? = nil, endpoint: ShedEndpoint?) {
        guard let endpoint else {
            loadedBase = nil
            webView.loadHTMLString(Self.unavailablePage, baseURL: nil)
            return
        }
        // Coming back to the tab must not reload the page and lose what was open.
        if sessionID == nil, loadedBase == endpoint.baseURL { return }
        loadedBase = endpoint.baseURL
        let url = endpoint.pageURL(sessionID: sessionID)
        let load: () -> Void = { [webView] in _ = webView.load(URLRequest(url: url)) }
        // The master token goes only to a Shed on this Mac. A Shed at another address
        // shows its own sign-in page instead.
        guard endpoint.isLoopback, let host = endpoint.baseURL.host, let token = endpoint.readToken(),
            let cookie = HTTPCookie(properties: [.name: "laya_auth", .value: token, .domain: host, .path: "/"])
        else { return load() }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie, completionHandler: load)
    }

    private static let unavailablePage = """
        <body style='font:15px -apple-system;margin:48px;color:#888'>
        Shed is not running on this Mac. Install or start Shed, or set its address in
        Settings, under Coding agents. Then open this tab again.</body>
        """

    // The web view stays on Shed's own origin (scheme, host and port): the cookie is not
    // port-scoped, and the page has the open panel. A clicked web link that leaves Shed
    // (docs, Tailscale pages) opens in the browser. Any other way out is refused.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url, action.targetFrame?.isMainFrame != false,
            url.scheme != "about", !Self.sameOrigin(url, loadedBase)
        else { return decisionHandler(.allow) }
        if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    nonisolated static func sameOrigin(_ url: URL, _ base: URL?) -> Bool {
        guard let base else { return false }
        return url.scheme == base.scheme && url.host == base.host && url.port == base.port
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

/// The Coding tab: Shed's page edge to edge in the detail pane. Shed brings its own
/// sidebar and headers, so the tab adds no title of its own.
struct ShedCodingView: View {
    let state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // `ImageRenderer` cannot draw a web view, so the snapshot shows a stand-in.
            Text("Shed").font(Typography.body).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ShedWebView()
                .task { ShedPage.shared.show(endpoint: await state.agents.shed.activeEndpoint) }
        }
    }
}

private struct ShedWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { ShedPage.shared.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
