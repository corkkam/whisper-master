import Foundation

/// Tools over the items a listing showed: `search_mail`, `read_item`,
/// `reply_message`, and the dormant Gmail `send_mail` / `reply_mail`.
///
/// **The model names an item by its row number, never by an id.** `list_mail`,
/// `list_messages` and `search_mail` number their rows ("3. …"), and the run's
/// `ItemHandles` maps each number to the real item. `ToolRouter` resolves the row to
/// the real target before `WriteAuthorizer` and the card, so a row number never
/// reaches a `Grant` or a card, and a model cannot copy an id wrong or make one up.
enum ItemTools {
    static let searchMail = "search_mail"
    static let readItem = "read_item"
    static let replyMessage = "reply_message"
    static let sendMail = "send_mail"
    static let replyMail = "reply_mail"

    /// Rows one `search_mail` returns, across every mailbox it searched.
    static let searchLimit = 10

    /// The listings whose rows are numbered.
    static let numberedListings: Set<String> = ["list_mail", "list_messages", searchMail]

    static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: searchMail,
            summary: "Search the user's email. Rows are numbered.",
            access: .read,
            capability: .mail,
            targetArg: nil,
            parameters: [
                ToolParameter("query", isRequired: true,
                              description: "What to look for: a name, a topic or words from the mail."),
            ]),

        // No capability: it reads mail and messages, so `servable` decides.
        ToolDescriptor(
            name: readItem,
            summary: "Open one mail or message in full, by its row number from a listing.",
            access: .read,
            capability: nil,
            targetArg: nil,
            parameters: [
                ToolParameter("row", type: .integer, isRequired: true,
                              description: "The row number from list_mail, search_mail or list_messages."),
            ]),

        // The target is the channel the row resolves to, never a model argument.
        ToolDescriptor(
            name: replyMessage,
            summary: "Reply in the Slack thread of a message, by its row number from list_messages.",
            access: .write,
            capability: .messages,
            targetArg: "channel",
            parameters: [
                ToolParameter("row", type: .integer, isRequired: true,
                              description: "The row number of the message to answer."),
                ToolParameter("text", isRequired: true, description: "The reply."),
            ]),

        ToolDescriptor(
            name: sendMail,
            summary: "Send a new email. Only to an address the user said or one in mail you read.",
            access: .write,
            capability: .mail,
            targetArg: "to",
            parameters: [
                ToolParameter("to", isRequired: true,
                              description: "Email address, or the name of a person whose mail you read."),
                ToolParameter("subject", isRequired: true, description: "The subject line."),
                ToolParameter("body", isRequired: true, description: "The whole message."),
            ]),

        ToolDescriptor(
            name: replyMail,
            summary: "Reply by email to a mail, by its row number from list_mail or search_mail.",
            access: .write,
            capability: .mail,
            targetArg: "to",
            parameters: [
                ToolParameter("row", type: .integer, isRequired: true,
                              description: "The row number of the mail to answer."),
                ToolParameter("body", isRequired: true, description: "The whole reply."),
            ]),
    ]

    /// A row tool takes no `connector` argument: the row decides the connection.
    static func takesRow(_ descriptor: ToolDescriptor) -> Bool {
        descriptor.parameters.contains { $0.name == "row" }
    }

    /// Mail send has no standing grant: the card shows every time, with no Always.
    static func grantable(_ tool: String) -> Bool {
        tool != sendMail && tool != replyMail
    }

    /// The connections that can serve `descriptor`: its capability's readable
    /// instances, narrowed for the tools only one provider answers.
    @MainActor
    static func servable(_ descriptor: ToolDescriptor,
                         store: ConnectorInstanceStore) -> [ConnectorInstance] {
        switch descriptor.name {
        case readItem:
            return store.readable(providing: .mail) + store.readable(providing: .messages)
        case replyMessage:
            return store.readable(providing: .messages).filter { $0.kind == .slack }
        case sendMail, replyMail:
            return store.readable(providing: .mail).filter(canSend)
        default:
            return descriptor.capability.map(store.readable(providing:)) ?? []
        }
    }

    /// Whether this Gmail connection may send: the build's gate is on and its grant
    /// carries `gmail.send`. A pasted token records no scope, so it never sends.
    @MainActor
    static func canSend(_ instance: ConnectorInstance) -> Bool {
        guard instance.kind == .gmail, GoogleOAuthConfig.isGmailSendEnabled else { return false }
        return sendPublished(gateOn: true,
                             grantedScope: ConnectorCredentials.load(for: instance.id)?["scope"])
    }

    /// The rule `canSend` applies, without the build or the Keychain.
    static func sendPublished(gateOn: Bool, grantedScope: String?) -> Bool {
        gateOn && (grantedScope ?? "").split(separator: " ")
            .contains { $0 == GoogleOAuthConfig.Scope.gmailSend }
    }

    /// What a row that is not in this run's table answers. It says what to do instead,
    /// because a model told only "no" tries the same number again.
    static func unknownRow(_ value: String?) -> String {
        "There is no row \(value ?? "") in this run. Call list_mail, search_mail or "
            + "list_messages first, then use a row number from that result."
    }

    static func replySubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
    }

    /// `read_item`'s text: the header fields that are set, then the body, inside the
    /// reducer's budget. Cut here, not by `ToolResultReducer.reduce`: a body with two
    /// lines that end in "]" would read there as a listing and lose its order.
    static func render(_ opened: OpenedItem, row: Int, label: String) -> String {
        let fields = [("From", opened.from), ("To", opened.to), ("Cc", opened.cc),
                      ("Reply-To", opened.replyTo), ("Date", opened.date), ("Subject", opened.subject)]
        let head = ["Row \(row), \(label):"] + fields.filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        let text = (head + ["", opened.body.isEmpty ? "(no text)" : opened.body]).joined(separator: "\n")
        return text.count > ToolResultReducer.budget
            ? ToolResultReducer.cut(text, budget: ToolResultReducer.budget)
            : text
    }
}

/// One address a mail header named, with the display name beside it.
struct MailAddress: Equatable, Sendable {
    let name: String
    let address: String

    private static let pattern = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

    /// The addresses in a header value ("Priya Raman <priya@acme.com>, sam@acme.com").
    /// shortcut: splits on commas, so a quoted display name that holds a comma loses
    /// its name (the address is still found). Parse quotes if a name lookup misses.
    static func parse(_ header: String) -> [MailAddress] {
        header.split(separator: ",").compactMap { segment in
            let text = String(segment)
            guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { return nil }
            let name = text.components(separatedBy: "<").count > 1
                ? text.components(separatedBy: "<")[0]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespacesAndNewlines))
                : ""
            return MailAddress(name: name, address: String(text[range]))
        }
    }

    /// The addresses the user said. Speech writes "priya at acme dot com", so that
    /// form is read as an address too.
    static func spoken(_ text: String) -> [String] {
        let written = text.lowercased()
            .replacingOccurrences(of: " at ", with: "@")
            .replacingOccurrences(of: " dot ", with: ".")
        return parse(written).map(\.address) + parse(text.lowercased()).map(\.address)
    }
}

/// The rows this run's listings showed, by number, and the mail addresses they named.
/// One per `ToolRouter`, and `CommandAgentService` builds one router per run, so a row
/// number from an earlier run (a follow-up) is unknown here and fails closed.
@MainActor
final class ItemHandles {
    struct Row: Equatable, Sendable {
        let instanceID: UUID
        let capability: ConnectorCapability
        let item: ConnectorItem
    }

    private(set) var rows: [Row] = []
    /// Addresses from the sender and recipient fields of mail this run read. Never from
    /// a body: an address written in a mail must not choose where mail goes.
    private(set) var addresses: [MailAddress] = []

    /// Adds a row and returns its number. Numbers count from 1 across the whole run,
    /// so a number never means two items.
    func add(_ item: ConnectorItem, instanceID: UUID, capability: ConnectorCapability) -> Int {
        rows.append(Row(instanceID: instanceID, capability: capability, item: item))
        // A mail row's detail is its From header (Gmail). Outlook's has no address.
        if capability == .mail { note(item.detail) }
        return rows.count
    }

    func row(_ number: Int) -> Row? {
        rows.indices.contains(number - 1) ? rows[number - 1] : nil
    }

    func note(_ opened: OpenedItem) {
        for header in [opened.from, opened.to, opened.cc, opened.replyTo] { note(header) }
    }

    private func note(_ header: String) {
        for address in MailAddress.parse(header)
        where !addresses.contains(where: { $0.address.lowercased() == address.address.lowercased() }) {
            addresses.append(address)
        }
    }

    enum Recipients: Equatable {
        case resolved([String])
        case refused(String)
    }

    /// `send_mail`'s `to`, checked. An address must be one the user said or one in a
    /// header this run read; a name must match exactly one read address. Anything else
    /// is refused with what the model can do, never guessed: an injected mail must not
    /// choose the recipient.
    func recipients(_ field: String, spoken: String) -> Recipients {
        let asked = field.split { $0 == "," || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !asked.isEmpty else { return .refused("send_mail needs \"to\".") }
        let said = Set(MailAddress.spoken(spoken))
        var resolved: [String] = []
        for entry in asked {
            if let address = MailAddress.parse(entry).first?.address {
                let key = address.lowercased()
                guard said.contains(key) || addresses.contains(where: { $0.address.lowercased() == key }) else {
                    return .refused("\(address) is not an address the user said or one in mail read "
                        + "in this run, so nothing was sent. Ask the user to say the address.")
                }
                resolved.append(address)
                continue
            }
            let name = entry.lowercased()
            let hits = addresses.filter {
                $0.name.lowercased() == name
                    || $0.name.split(separator: " ").first.map { $0.lowercased() == name } == true
            }
            switch Set(hits.map { $0.address.lowercased() }).count {
            case 0:
                return .refused("No address for \(entry) is in mail read in this run, so nothing "
                    + "was sent. Search the mail for \(entry) first, or ask the user for the address.")
            case 1:
                resolved.append(hits[0].address)
            default:
                let options = hits.map { "\($0.name) <\($0.address)>" }.prefix(4).joined(separator: "; ")
                return .refused("\(entry) matches more than one address: \(options). Nothing was "
                    + "sent. Ask the user which one, then call send_mail with the full address.")
            }
        }
        return .resolved(resolved)
    }
}

// MARK: - Routing

extension ToolRouter {
    /// The item tools that need more than a listing read. Nil for every other tool,
    /// which `run` then routes as before. `search_mail` is an ordinary read.
    func runItemTool(_ call: ToolCall, descriptor: ToolDescriptor) async -> ToolResult? {
        switch call.tool {
        case ItemTools.readItem: return await readItem(call)
        case ItemTools.replyMessage, ItemTools.replyMail: return await reply(call, descriptor: descriptor)
        case ItemTools.sendMail: return await sendMail(call, descriptor: descriptor)
        default: return nil
        }
    }

    /// The row the call names and the connection it came from, or nil.
    private func handle(_ call: ToolCall) -> (number: Int, row: ItemHandles.Row, instance: ConnectorInstance)? {
        guard let number = call.arguments["row"].flatMap(Int.init),
              let row = handles.row(number),
              let instance = store.instance(id: row.instanceID)
        else { return nil }
        return (number, row, instance)
    }

    private func readItem(_ call: ToolCall) async -> ToolResult {
        guard let found = handle(call) else {
            return .failure(ItemTools.unknownRow(call.arguments["row"]))
        }
        let (number, row, instance) = found
        let label = instance.displayLabel
        let opened: OpenedItem
        if let opener = itemProvider(instance) as? any ItemOpeningProvider {
            let outcome = await opener.openItem(row.item, for: instance)
            if let error = outcome.error {
                if !Task.isCancelled { store.setError(instance.id, error) }
                return ToolResult(ok: false, text: "[\(label)] couldn't be read: \(error.message)",
                                  instanceLabels: [], unreadable: [label])
            }
            guard let value = outcome.value else { return .failure("Row \(number) couldn't be opened.") }
            opened = value
        } else if row.capability == .messages {
            opened = OpenedItem(row: row.item)
        } else {
            return .failure("\(label) can't open one item.")
        }
        handles.note(opened)
        // Text written by somebody else, like any connector read.
        taint.isSet = true
        taint.outsideSelection = true
        return ToolResult(ok: true, text: ItemTools.render(opened, row: number, label: label),
                          instanceLabels: [label])
    }

    /// `reply_message` and `reply_mail`: the row becomes the real channel or address,
    /// then the call takes the ordinary write path (authorizer, card, provider).
    private func reply(_ call: ToolCall, descriptor: ToolDescriptor) async -> ToolResult {
        guard let found = handle(call) else {
            return .failure(ItemTools.unknownRow(call.arguments["row"]))
        }
        let (number, row, instance) = found
        var resolved: [String: String]
        if call.tool == ItemTools.replyMessage {
            guard instance.kind == .slack, let target = SlackProvider.replyTarget(for: row.item) else {
                return .failure("Row \(number) is not a Slack message. reply_message answers a Slack "
                    + "message row from list_messages; use send_message to post in a channel.")
            }
            resolved = ["channel": target.channel, "channel_id": target.channelID,
                        "thread_ts": target.threadTS, "to": target.author]
        } else {
            guard row.capability == .mail, ItemTools.canSend(instance),
                  let opener = itemProvider(instance) as? any ItemOpeningProvider
            else {
                return .failure("Row \(number) is not a mail this app can answer. reply_mail answers "
                    + "a Gmail row from list_mail or search_mail.")
            }
            let outcome = await opener.openItem(row.item, for: instance)
            guard outcome.error == nil, let opened = outcome.value, let to = opened.replyAddress else {
                return .failure("Couldn't read row \(number) to answer it, so nothing was sent.")
            }
            resolved = ["to": to, "subject": ItemTools.replySubject(opened.subject),
                        "thread_id": opened.threadID ?? "", "in_reply_to": opened.messageID ?? "",
                        "references": opened.references ?? ""]
        }
        for key in ["text", "body"] { resolved[key] = call.arguments[key] }
        return await write(ToolCall(tool: call.tool, arguments: resolved.filter { !$0.value.isEmpty }),
                           descriptor: descriptor, instance: instance)
    }

    private func sendMail(_ call: ToolCall, descriptor: ToolDescriptor) async -> ToolResult {
        let candidates = ItemTools.servable(descriptor, store: store)
        guard !candidates.isEmpty else { return .failure("Sending mail is not turned on.") }
        let instance = call.arguments[ToolDescriptor.instanceArgument]
            .flatMap { ConnectorLabelMatcher.match($0, in: candidates) }
            ?? candidates.first { store.isDefault($0.id) }
            ?? candidates[0]
        switch handles.recipients(call.arguments["to"] ?? "", spoken: spoken) {
        case .refused(let reason):
            return .failure(reason)
        case .resolved(let addresses):
            var arguments = call.arguments
            arguments["to"] = addresses.joined(separator: ", ")
            return await write(ToolCall(tool: call.tool, arguments: arguments),
                               descriptor: descriptor, instance: instance)
        }
    }
}
