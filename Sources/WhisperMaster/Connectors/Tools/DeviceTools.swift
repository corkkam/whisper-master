import AppKit

/// An app on this Mac, found by the name a person says.
struct InstalledApp: Equatable, Sendable {
    let name: String
    let url: URL
}

/// Finds an installed app by name. Plain directory listings: a few hundred entries,
/// read on demand, so a newly installed app is found on the next command.
enum InstalledApps {
    // shortcut: one folder level only, so an app inside a vendor folder
    // (/Applications/Adobe Photoshop 2025/…) is not found; add a second level when
    // somebody asks for one.
    static let folders: [URL] = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
    ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        + [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)]

    /// Finder lives in CoreServices, beside dozens of system agents nobody opens by
    /// voice, so it is named rather than that folder listed.
    private static let finder = InstalledApp(
        name: "Finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))

    /// The app whose name reads the same as `spoken`, ignoring case and punctuation.
    /// Exact, never fuzzy: the fast path acts with no model and no card, so a near
    /// miss must fall through to the agent rather than open the wrong app.
    static func match(_ spoken: String, in apps: [InstalledApp]) -> InstalledApp? {
        let wanted = normalized(spoken)
        guard !wanted.isEmpty else { return nil }
        return apps.first { normalized($0.name) == wanted }
    }

    static func find(_ spoken: String) -> InstalledApp? {
        match(spoken, in: scan())
    }

    static func scan() -> [InstalledApp] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
                .map { InstalledApp(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
        } + [finder]
    }

    /// Lowercased letters and digits, single-spaced: "Visual Studio Code." and
    /// "visual studio code" are one name.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
}

/// The tools that act on this Mac rather than on a connector: open an app, open a
/// link, and put text the assistant wrote into the app the user was in.
///
/// None of them has a connection behind it, so the connector write path (which
/// resolves a `ConnectorInstance` first) cannot carry them. `DeviceToolRunner` is
/// their route: the same `WriteAuthorizer` and the same card, bound to the fixed
/// `thisMacID` instead of a connection.
enum DeviceToolCatalog {
    /// The "connection" a device grant binds to. Fixed, so a grant made today still
    /// matches tomorrow, and never the id of a real `ConnectorInstance`.
    static let thisMacID = UUID(uuidString: "7E15AC00-0000-4000-8000-000000000001")!
    static let thisMacLabel = "This Mac"

    /// The longest link the card can show in full, on three caption lines. A link
    /// the card would have to cut is refused rather than half-shown.
    static let maxURLLength = 150

    static let openApp = ToolDescriptor(
        name: "open_app",
        summary: "Open an app installed on this Mac.",
        access: .write,
        capability: nil,
        targetArg: "app",
        parameters: [
            ToolParameter("app", isRequired: true, description: "The app's name, as the user said it."),
        ])

    static let openURL = ToolDescriptor(
        name: "open_url",
        summary: "Open a web page in the browser.",
        access: .write,
        capability: nil,
        targetArg: "url",
        parameters: [
            ToolParameter("url", isRequired: true, description: "The full http or https address."),
        ])

    /// `.local`, like a note: staging a draft changes nothing. The tap on the band is
    /// the consent, so there is no card and no grant.
    static let replaceSelection = ToolDescriptor(
        name: "replace_selection",
        summary: "Rewrite the text the user selected. Use this when they ask to shorten, fix, "
            + "rephrase or translate it. They review it before it replaces the selection.",
        access: .local,
        capability: nil,
        targetArg: nil,
        parameters: [
            ToolParameter("text", isRequired: true, description: "The full new text."),
        ])

    static let insertText = ToolDescriptor(
        name: "insert_text",
        summary: "Write new text into the app the user is in. Use this only when they ask you "
            + "to write or type something there. They review it before it is typed.",
        access: .local,
        capability: nil,
        targetArg: nil,
        parameters: [
            ToolParameter("text", isRequired: true, description: "The text to type."),
        ])

    static let all = [openApp, openURL, replaceSelection, insertText] + FileToolCatalog.all
    static let names: Set<String> = Set(all.map(\.name))

    static func descriptor(named name: String) -> ToolDescriptor? {
        all.first { $0.name == name }
    }

    /// The tools one run offers. The draft tools need the app that was in front at
    /// key-down, and `replace_selection` also needs a selection to replace.
    static func offered(selection: Bool, frontApp: Bool) -> [ToolDescriptor] {
        let files = FileToolCatalog.all
        guard frontApp else { return [openApp, openURL] + files }
        return [openApp, openURL] + files + (selection ? [replaceSelection] : []) + [insertText]
    }

    /// Whether a standing grant may cover the tool. A link is shown on the card
    /// every time: the address is the whole of the risk, and it changes per call. A
    /// file is the same: a grant would have to bind to a name, and the next file of
    /// that name is another file.
    static func grantable(_ tool: String) -> Bool {
        tool != openURL.name && tool != FileToolCatalog.openFile.name
    }

    // MARK: - What a trace keeps

    static let draftToolNames: Set<String> = [replaceSelection.name, insertText.name]

    /// What a trace keeps in place of a draft: its length. Traces persist, and a
    /// draft is a rewrite of the user's text from another app, which the selection's
    /// own 40-character rule (`SelectionContext.storable`) does not catch.
    static func draftPlaceholder(_ text: String) -> String {
        "[draft, \(text.count) characters]"
    }

    /// `text` with every copy of `draft` kept as its length: as written, and as a
    /// model writes it inside JSON (`\n`, `\"`), where a plain search misses it.
    static func strip(_ draft: String, from text: String) -> String {
        let placeholder = draftPlaceholder(draft)
        var kept = text.replacingOccurrences(of: draft, with: placeholder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        if let data = try? encoder.encode(draft),
           let quoted = String(data: data, encoding: .utf8), quoted.count > 2 {
            kept = kept.replacingOccurrences(of: String(quoted.dropFirst().dropLast()), with: placeholder)
        }
        return kept
    }

    /// A call's arguments as the journal may keep them.
    static func storableArguments(_ call: ToolCall) -> [String: String] {
        guard draftToolNames.contains(call.tool) else { return call.arguments }
        return call.arguments.mapValues(draftPlaceholder)
    }

    /// A model turn as a trace may keep it: one that calls a draft tool keeps the
    /// call's shape and loses the text, malformed or not. The native parser reads both
    /// shapes: the on-device `{"tool":…}` and the endpoint's `<tool_call>{"name":…}`.
    static func storableTurn(_ text: String) -> String {
        guard let tool = draftToolNames.sorted().first(where: { text.contains($0) }) else { return text }
        var draft = text
        if case .success(.call(let call)) = NativeToolCallParser.parse(text, tools: all),
           let body = call.arguments["text"] {
            draft = body
        }
        return #"{"tool":"\#(tool)","args":{"text":"\#(draftPlaceholder(draft))"}}"#
    }

    // MARK: - The link card's headline

    /// Width the headline may take on the wide card beside Once and No: the text
    /// column there measures about 426 pt (`pill-9g`), so this leaves a margin for a
    /// narrower notch. A link card never shows Always, which would take more.
    static let linkHeadlineWidth: CGFloat = 380

    /// "Open <host> in your browser", measured in the card's title font. A long host
    /// loses labels from its **front**, so the end, where the registrable domain is,
    /// stays on screen: a tail cut would show `accounts.google.com.…` for a host that
    /// ends in somebody else's domain. Nil when even the domain does not fit, and the
    /// link is then refused rather than shown as a prefix that misleads.
    static func linkHeadline(host: String) -> String? {
        func line(_ shown: String) -> String { "Open \(shown) in your browser" }
        guard width(of: line(host)) > linkHeadlineWidth else { return line(host) }
        var labels = host.split(separator: ".").map(String.init)
        while labels.count > registrableLabels(labels) {
            labels.removeFirst()
            let candidate = line("\u{2026}" + labels.joined(separator: "."))
            if width(of: candidate) <= linkHeadlineWidth { return candidate }
        }
        return nil
    }

    /// Labels the registrable domain takes: two, or three under a short second level
    /// of a country code (`example.co.uk`).
    // shortcut: no public suffix list, so a rarer suffix (`example.blogspot.com`) can
    // be cut to its suffix plus one; ship the list if links like that matter.
    private static func registrableLabels(_ labels: [String]) -> Int {
        guard labels.count >= 3, let top = labels.last, top.count == 2,
              labels[labels.count - 2].count <= 3
        else { return min(2, labels.count) }
        return 3
    }

    /// The headline's width in `Typography.notchTitle`, the face the card sets it in.
    private static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: titleFont]).width)
    }

    nonisolated(unsafe) private static let titleFont: NSFont = {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: BrandFont.body])
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]])
        return NSFont(descriptor: descriptor, size: 12) ?? .systemFont(ofSize: 12, weight: .semibold)
    }()

    /// An http or https link from the model's argument, or nil. A bare domain
    /// ("github.com") is read as https; any other scheme, a link with a user name in
    /// it (`https://github.com@evil.example`), or one with no host is refused.
    static func webURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }
}

/// Text the assistant wrote for the app the user was in, waiting on the band.
///
/// Held in memory only (`AppState.agentDraft`). The model never types: the band
/// shows this, and the user's tap types it with a real ⌘V, never followed by Return.
struct AgentDraft: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case replaceSelection
        case insertText
    }

    let kind: Kind
    /// Exactly what a tap types or copies.
    let text: String
    /// The app in front at key-down: the only app a tap may type into.
    let app: SelectionReader.FrontApp
    /// The selection a Replace types over. Read again at the tap, and a selection
    /// that changed since makes the tap a copy, so a rewrite never lands on other text.
    let selection: String?
    /// Why the band offers Copy instead of typing, or nil when it may type.
    let copyOnlyReason: String?

    var actionTitle: String {
        guard copyOnlyReason == nil else { return "Copy" }
        return kind == .replaceSelection ? "Replace" : "Insert"
    }

    static let focusMoved = "You switched apps after you spoke, so this is copy only."
    static let afterReading = "I wrote this after reading text from your accounts, so this is copy only."
    static let afterReadingSelection = "I wrote this after reading your selection, so this is copy only."
    static let multiLineInTerminal = "A terminal runs each line, so a multi-line draft is copy only."
    static let hiddenCharacters = "The draft has characters the band can't show, so this is copy only."
    static let selectionCut = "The selection was too long to rewrite safely, so this is copy only."
    static let selectionChanged = "The selection changed, so this is copy only."
    static let textSelected = "Text is selected, so inserting would replace it. This is copy only."

    /// The insert rules, in one place, or nil for a draft with nothing in it.
    ///
    /// - Focus that moved since key-down makes it copy only: the words were meant
    ///   for the other app.
    /// - A control or format character the band cannot show (an escape sequence, a
    ///   bidi override, a zero-width mark) makes it copy only: the tap must type
    ///   exactly what the user read. A tab is allowed, and so is a line break outside
    ///   a terminal.
    /// - A Replace of a selection cut at `SelectionReader.limit` is copy only: the
    ///   rewrite covers the part that was read, and the paste replaces all of it.
    /// - Text from an account (mail, chat) read in this run makes it copy only.
    /// - The run's own selection read is exempt in one case only: a Replace outside a
    ///   terminal, where "make this shorter" types a rewrite back over the text it
    ///   read. An insert, or anything in a terminal, after that read is copy only.
    /// - A terminal loses trailing newlines (one would run the command), and a
    ///   multi-line draft there is copy only (each line would run).
    static func stage(_ kind: Kind,
                      text: String,
                      app: SelectionReader.FrontApp,
                      selection: String?,
                      selectionWasCut: Bool,
                      frontNow: SelectionReader.FrontApp?,
                      tainted: Bool,
                      readOutsideSelection: Bool) -> AgentDraft? {
        let terminal = TerminalApps.isTerminal(bundleID: app.bundleID)
        var text = text
        if terminal {
            while let last = text.last, last.isNewline { text.removeLast() }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let reason: String?
        if frontNow?.pid != app.pid {
            reason = focusMoved
        } else if hasHiddenCharacters(text) {
            reason = hiddenCharacters
        } else if kind == .replaceSelection, selectionWasCut {
            reason = selectionCut
        } else if readOutsideSelection {
            reason = afterReading
        } else if tainted, kind == .insertText || terminal {
            reason = afterReadingSelection
        } else if terminal, text.contains(where: \.isNewline) {
            reason = multiLineInTerminal
        } else {
            reason = nil
        }
        return AgentDraft(kind: kind, text: text, app: app, selection: selection,
                          copyOnlyReason: reason)
    }

    /// Any Cc or Cf scalar except a tab and a line break. Line breaks are left to the
    /// terminal rule, which is the one place they run something.
    static func hasHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar != "\t", scalar != "\n", scalar != "\r" else { return false }
            switch scalar.properties.generalCategory {
            case .control, .format: return true
            default: return false
            }
        }
    }

    /// Whether the tap reads the selection before it types. Not for an Insert in a
    /// terminal: ⌘V there types at the prompt and replaces nothing, so highlighted
    /// text is no reason to copy. Warp is the exception: its prompt is an editor, where
    /// ⌘V replaces a selection (`TerminalApps.editorInputBundleIDs`).
    var readsSelectionAtTap: Bool {
        kind == .replaceSelection || !TerminalApps.isTerminal(bundleID: app.bundleID)
            || TerminalApps.editorInputBundleIDs.contains(app.bundleID ?? "")
    }

    /// Why a tap must copy, from the selection read again at the tap. A Replace types
    /// only over the exact text it was written for, read whole. An Insert copies over
    /// a selection it can see, since ⌘V replaces it. Over one it cannot see (Chrome,
    /// Electron, a read past the wait) it still types, and `typedLine` says so.
    func selectionBlocker(current: SelectionReader.SelectionState) -> String? {
        switch (kind, current) {
        case (.replaceSelection, .selected(let now)):
            if now.wasCut { return Self.selectionCut }
            return now.text == selection ? nil : Self.selectionChanged
        case (.replaceSelection, .empty), (.replaceSelection, .unknown):
            return Self.selectionChanged
        case (.insertText, .selected):
            return Self.textSelected
        case (.insertText, .empty), (.insertText, .unknown):
            return nil
        }
    }

    /// The status line once the tap has typed. `read` is what the tap read, or nil
    /// when it read nothing (`readsSelectionAtTap`). When the app could not say what
    /// was selected, ⌘V may have replaced text, so the line says how to undo it.
    func typedLine(after read: SelectionReader.SelectionState?) -> String {
        switch kind {
        case .replaceSelection:
            return "Replaced the selection in \(app.name)."
        case .insertText where read == .unknown:
            return Self.typedOverUnknownSelection
        case .insertText:
            return "Typed the draft into \(app.name)."
        }
    }

    /// No app name, so it stays inside the status line's 60 characters.
    static let typedOverUnknownSelection = "Pasted. If text was selected, Cmd-Z restores it."

    /// The same draft, made copy only because a check at the tap failed.
    func copyOnly(_ reason: String) -> AgentDraft {
        AgentDraft(kind: kind, text: text, app: app, selection: selection, copyOnlyReason: reason)
    }
}

/// Runs a `DeviceToolCatalog` call. The approval route for tools with no connector.
///
/// `open_app` and `open_url` go through `WriteAuthorizer` and the card like a
/// connector write, scoped to `DeviceToolCatalog.thisMacID`, and the run's taint
/// works the same way: after untrusted text, a grant does not answer and the card
/// offers no Always. A link never gets Always at all. The draft tools only stage a
/// draft; nothing reaches another app until the user taps the band.
@MainActor
struct DeviceToolRunner {
    /// What the runner touches outside itself. Injected so a test can open nothing.
    struct Environment {
        var installedApp: @MainActor (String) -> InstalledApp?
        var openApp: @MainActor (URL) -> Bool
        var openURL: @MainActor (URL) -> Bool
        var frontApp: @MainActor () -> SelectionReader.FrontApp?
        var findFiles: @MainActor (FileQuery) async -> FileSearchOutcome = { _ in FileSearchOutcome() }
        var openFile: @MainActor (URL) -> Bool = { _ in false }

        @MainActor static let live = Environment(
            installedApp: { InstalledApps.find($0) },
            openApp: { NSWorkspace.shared.open($0) },
            openURL: { NSWorkspace.shared.open($0) },
            frontApp: { SelectionReader.FrontApp.current() },
            findFiles: { await SpotlightFileSearch.search($0) },
            openFile: { NSWorkspace.shared.open($0) })
    }

    /// What a call did.
    enum Effect: Equatable, Sendable {
        case openedApp(name: String)
        case openedURL(host: String)
        case openedFile(name: String)
        case draftStaged(AgentDraft)
    }

    let store: ConnectorInstanceStore
    let requestApproval: (PendingApproval) async -> ApprovalOutcome
    var environment: Environment = .live
    /// Shared with the run's other routers, as `LocalToolRunner` shares it.
    var taint = Taint()
    /// The rows of this run's latest `find_files`, the only files `open_file` may open.
    var fileRows = FileRowTable()
    /// The app in front at key-down, or nil: no draft tool then.
    var frontApp: SelectionReader.FrontApp?
    /// What the user had selected at key-down, or nil.
    var selection: SelectionContext?
    var now: () -> Date = Date.init

    static let stoppedBeforeOpen = "Stopped before it ran, so nothing was opened."

    func run(_ call: ToolCall) async -> (result: ToolResult, effect: Effect?) {
        switch call.tool {
        case DeviceToolCatalog.openApp.name: return await openApp(call)
        case DeviceToolCatalog.openURL.name: return await openURL(call)
        case FileToolCatalog.findFiles.name: return await findFiles(call)
        case FileToolCatalog.openFile.name: return await openFile(call)
        case DeviceToolCatalog.replaceSelection.name: return stage(.replaceSelection, call)
        case DeviceToolCatalog.insertText.name: return stage(.insertText, call)
        default: return (.failure("No such tool: \(call.tool)."), nil)
        }
    }

    // MARK: - Opening

    private func openApp(_ call: ToolCall) async -> (ToolResult, Effect?) {
        let spoken = call.arguments["app"] ?? ""
        guard let app = environment.installedApp(spoken) else {
            return (.failure("No app called \u{201C}\(spoken)\u{201D} is installed on this Mac."), nil)
        }
        switch await authorize(DeviceToolCatalog.openApp, target: app.name, arguments: ["app": app.name]) {
        case .stop(let result):
            return (result, nil)
        case .go(let authorization, let waited):
            let opened = environment.openApp(app.url)
            return (ToolResult(ok: opened,
                               text: opened ? "Opened \(app.name)." : "Couldn't open \(app.name).",
                               instanceLabels: opened ? [DeviceToolCatalog.thisMacLabel] : [],
                               authorization: authorization,
                               approvalMilliseconds: waited),
                    opened ? .openedApp(name: app.name) : nil)
        }
    }

    private func openURL(_ call: ToolCall) async -> (ToolResult, Effect?) {
        guard let url = DeviceToolCatalog.webURL(call.arguments["url"] ?? ""),
              let host = url.host()
        else { return (.failure("Only an http or https link can be opened."), nil) }
        let link = url.absoluteString
        guard link.count <= DeviceToolCatalog.maxURLLength,
              DeviceToolCatalog.linkHeadline(host: host) != nil
        else {
            return (.failure("That link is too long to show in full on the card, so it wasn't opened."), nil)
        }
        // A query or a fragment is the easiest place for read text to ride out, so a
        // tainted run refuses one. It can leave in a path or a subdomain as well; the
        // card on every link, with the whole address on it, is what covers those.
        if taint.isSet, url.query() != nil || url.fragment() != nil {
            return (.failure("This run read text from your accounts or your selection, so a link "
                + "with a query or a fragment can't be opened."), nil)
        }
        switch await authorize(DeviceToolCatalog.openURL, target: link, arguments: ["url": link]) {
        case .stop(let result):
            return (result, nil)
        case .go(let authorization, let waited):
            let opened = environment.openURL(url)
            return (ToolResult(ok: opened,
                               text: opened ? "Opened \(host) in the browser." : "Couldn't open \(host).",
                               instanceLabels: opened ? [DeviceToolCatalog.thisMacLabel] : [],
                               authorization: authorization,
                               approvalMilliseconds: waited),
                    opened ? .openedURL(host: host) : nil)
        }
    }

    enum Gate {
        case go(ToolAuthorization, waited: Int)
        case stop(ToolResult)
    }

    /// The card, scoped to This Mac. Mirrors `ToolRouter.write`'s handling of each
    /// answer, so a device call and a connector write read the same in a trace.
    func authorize(_ descriptor: ToolDescriptor,
                   target: String,
                   arguments: [String: String]) async -> Gate {
        let grantable = DeviceToolCatalog.grantable(descriptor.name)
        switch WriteAuthorizer.authorize(tool: descriptor,
                                         instanceID: DeviceToolCatalog.thisMacID,
                                         target: target,
                                         grants: store.grants,
                                         tainted: taint.isSet) {
        case .refused(let reason):
            return .stop(.failure(reason))
        case .granted where grantable:
            return .go(.standingGrant, waited: 0)
        case .granted, .needsApproval:
            break
        }
        guard !Task.isCancelled else { return .stop(.failure(Self.stoppedBeforeOpen)) }
        let askedAt = now()
        let outcome = await requestApproval(PendingApproval(
            tool: descriptor.name,
            instanceID: DeviceToolCatalog.thisMacID,
            instanceLabel: DeviceToolCatalog.thisMacLabel,
            target: target,
            arguments: arguments,
            grantOffered: !taint.isSet,
            grantable: grantable,
            readSelectionOnly: taint.isSet && !taint.outsideSelection))
        let waited = Int(now().timeIntervalSince(askedAt) * 1000)
        let authorization: ToolAuthorization
        switch outcome {
        case .denied:
            return .stop(ToolResult(ok: false, text: "The user declined that.", instanceLabels: [],
                                    authorization: .denied, approvalMilliseconds: waited))
        case .timedOut:
            return .stop(ToolResult(ok: false,
                                    text: "Nobody answered the approval card in time, so nothing was opened.",
                                    instanceLabels: [], authorization: .timedOut,
                                    approvalMilliseconds: waited))
        case .allowedAlways where grantable && !taint.isSet:
            store.addGrant(Grant(tool: descriptor.name, instanceID: DeviceToolCatalog.thisMacID,
                                 target: target))
            authorization = .allowedAlways
        case .allowedAlways, .allowedOnce:
            // The card hides Always for a link and in a tainted run, so only a caller
            // that ignores `offersAlways` answers it there: run once, store nothing.
            authorization = .allowedOnce
        }
        guard !Task.isCancelled else {
            return .stop(ToolResult(ok: false, text: Self.stoppedBeforeOpen, instanceLabels: [],
                                    approvalMilliseconds: waited))
        }
        return .go(authorization, waited: waited)
    }

    // MARK: - Drafts

    private func stage(_ kind: AgentDraft.Kind, _ call: ToolCall) -> (ToolResult, Effect?) {
        guard let app = frontApp else { return (.failure("There is no app to type into."), nil) }
        if kind == .replaceSelection, selection == nil {
            return (.failure("Nothing is selected, so there is nothing to replace. Use insert_text."), nil)
        }
        guard let draft = AgentDraft.stage(
            kind,
            text: call.arguments["text"] ?? "",
            app: app,
            selection: kind == .replaceSelection ? selection?.text : nil,
            selectionWasCut: selection?.wasCut == true,
            frontNow: environment.frontApp(),
            tainted: taint.isSet,
            readOutsideSelection: taint.outsideSelection)
        else { return (.failure("The draft is empty."), nil) }
        let text = draft.copyOnlyReason.map { "The draft is on screen for the user to copy. \($0)" }
            ?? "The draft is on screen. Nothing is typed until the user taps \(draft.actionTitle)."
        return (ToolResult(ok: true, text: text, instanceLabels: []), .draftStaged(draft))
    }
}
