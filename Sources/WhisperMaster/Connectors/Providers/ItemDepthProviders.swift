import Foundation

/// The provider half of `search_mail`, `read_item`, `reply_message` and the dormant
/// Gmail send (`ItemTools`). `ItemReadingProvider` has only `recentItems`, so a search
/// and a one-item read are two more capability protocols, adopted only by the
/// providers that can answer them.

/// A provider that can search its items.
@MainActor
protocol ItemSearchingProvider: ItemReadingProvider {
    func searchItems(_ query: String, for instance: ConnectorInstance,
                     limit: Int) async -> ProviderReadOutcome<[ConnectorItem]>
}

/// A provider that can fetch the whole of one item a listing showed.
@MainActor
protocol ItemOpeningProvider: ItemReadingProvider {
    func openItem(_ item: ConnectorItem,
                  for instance: ConnectorInstance) async -> ProviderReadOutcome<OpenedItem?>
}

/// One mail or message as `read_item` shows it. Header fields are as the provider
/// gave them ("Name <address>"); the ids are what a reply needs.
struct OpenedItem: Equatable, Sendable {
    var from = ""
    var to = ""
    var cc = ""
    var replyTo = ""
    var date = ""
    var subject = ""
    var body = ""
    var threadID: String?
    /// The RFC 5322 `Message-ID` header, for `In-Reply-To`.
    var messageID: String?
    var references: String?

    /// A message row opened from what its listing already holds. Slack and Teams list
    /// the whole message text, so they need no second request.
    init(row item: ConnectorItem) {
        from = item.detail
        date = item.timestamp.map(MailText.date.string(from:)) ?? ""
        body = item.title
    }

    init(from: String = "", to: String = "", cc: String = "", replyTo: String = "",
         date: String = "", subject: String = "", body: String = "",
         threadID: String? = nil, messageID: String? = nil, references: String? = nil) {
        self.from = from
        self.to = to
        self.cc = cc
        self.replyTo = replyTo
        self.date = date
        self.subject = subject
        self.body = body
        self.threadID = threadID
        self.messageID = messageID
        self.references = references
    }

    /// Where a reply goes: Reply-To, else From. The address only.
    var replyAddress: String? {
        MailAddress.parse(replyTo).first?.address ?? MailAddress.parse(from).first?.address
    }
}

/// Mail text helpers shared by the Gmail and Outlook reads.
enum MailText {
    /// A body as plain text. A plain tag strip (the Teams one), after removing the
    /// blocks whose text is not content: a style sheet would otherwise read as words.
    static func plain(fromHTML html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: "(?is)<(style|script|head)\\b.*?</\\1\\s*>", with: " ", options: .regularExpression)
        return MicrosoftGraph.plainText(fromHTML: stripped)
    }

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy, h:mm a"
        return formatter
    }()

    /// A header value with its line breaks removed, so text the model wrote cannot
    /// start a second header (a `Bcc:` hidden in a subject).
    static func headerValue(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Gmail

extension GmailProvider: ItemSearchingProvider, ItemOpeningProvider {
    func searchItems(_ query: String, for instance: ConnectorInstance,
                     limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            try await Self.listMessages(token: token, query: query, limit: limit,
                                        instanceLabel: instance.displayLabel)
        }
    }

    func openItem(_ item: ConnectorItem,
                  for instance: ConnectorInstance) async -> ProviderReadOutcome<OpenedItem?> {
        await withResolvedToken(instance, empty: nil) { token in
            guard let url = Self.messageURL(id: item.id) else { return nil }
            return Self.openedItem(from: try await ConnectorHTTP.getJSON(url, token: token))
        }
    }

    static func messageURL(id: String) -> URL? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(encoded)?format=full")
    }

    /// A `format=full` message: its headers, its thread, and the first text/plain
    /// part, else the first text/html part as plain text.
    static func openedItem(from json: [String: Any]) -> OpenedItem {
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        func header(_ name: String) -> String {
            (headers.first {
                ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
            }?["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let body = firstPart(payload, mimeType: "text/plain")
            ?? firstPart(payload, mimeType: "text/html").map(MailText.plain(fromHTML:))
            ?? ""
        return OpenedItem(
            from: header("From"), to: header("To"), cc: header("Cc"),
            replyTo: header("Reply-To"), date: header("Date"), subject: header("Subject"),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            threadID: json["threadId"] as? String,
            messageID: header("Message-ID").isEmpty ? nil : header("Message-ID"),
            references: header("References").isEmpty ? nil : header("References"))
    }

    private static func firstPart(_ part: [String: Any], mimeType: String) -> String? {
        if (part["mimeType"] as? String)?.lowercased() == mimeType,
           let data = (part["body"] as? [String: Any])?["data"] as? String,
           let text = decodeBase64URL(data) {
            return text
        }
        for child in part["parts"] as? [[String: Any]] ?? [] {
            if let text = firstPart(child, mimeType: mimeType) { return text }
        }
        return nil
    }

    static func decodeBase64URL(_ text: String) -> String? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    static let sendURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!

    /// The `users.messages.send` body: an RFC 5322 message, base64url, plus the thread
    /// for a reply. Every header value loses its line breaks (`MailText.headerValue`),
    /// so the model's subject or recipients cannot add a header.
    static func sendBody(to: String, subject: String, body: String, threadID: String? = nil,
                         inReplyTo: String? = nil, references: String? = nil) -> [String: Any] {
        let subjectLine = MailText.headerValue(subject)
        // shortcut: one encoded-word for the whole subject; RFC 2047 wants 75-character
        // pieces, which Gmail does not enforce. Split it if a client shows it garbled.
        let encodedSubject = subjectLine.allSatisfy(\.isASCII)
            ? subjectLine
            : "=?UTF-8?B?\(Data(subjectLine.utf8).base64EncodedString())?="
        var headers = [
            "To: \(MailText.headerValue(to))",
            "Subject: \(encodedSubject)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
        ]
        if let inReplyTo = inReplyTo.map(MailText.headerValue), !inReplyTo.isEmpty {
            let chain = (references.map(MailText.headerValue) ?? "") + " " + inReplyTo
            headers += ["In-Reply-To: \(inReplyTo)",
                        "References: \(chain.trimmingCharacters(in: .whitespaces))"]
        }
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n"
            + Data(body.utf8).base64EncodedString(options: .lineLength76Characters)
        let raw = Data(message.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var json: [String: Any] = ["raw": raw]
        if let threadID, !threadID.isEmpty { json["threadId"] = threadID }
        return json
    }
}

extension GmailProvider: WriteCapableProvider {
    /// `send_mail` and `reply_mail`. The router has already checked the gate, the
    /// recipients and the card; this checks the gate again, because a provider that
    /// can send must not depend on one caller for that.
    func performWrite(tool: String,
                      arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        guard tool == ItemTools.sendMail || tool == ItemTools.replyMail else {
            return .failed("Gmail can't do \(tool).")
        }
        guard ItemTools.canSend(instance) else {
            return .failed("Sending mail is not turned on for \(instance.displayLabel).")
        }
        guard let to = arguments["to"], !to.isEmpty, let body = arguments["body"] else {
            return .failed("Missing a recipient or a body.")
        }
        let token: String
        do { token = try await CredentialStrategy.resolveAndPersist(for: instance) } catch {
            return .failed("Gmail credential unusable.")
        }
        do {
            _ = try await ConnectorHTTP.postJSON(Self.sendURL, token: token, body: Self.sendBody(
                to: to, subject: arguments["subject"] ?? "", body: body,
                threadID: arguments["thread_id"], inReplyTo: arguments["in_reply_to"],
                references: arguments["references"]))
            return .done("Sent mail to \(to) from \(instance.displayLabel).")
        } catch ConnectorHTTP.Failure.badStatus(_, let detail) {
            return .failed("Gmail refused: \(detail.prefix(200))")
        } catch ConnectorHTTP.Failure.unauthorized {
            return .failed("Gmail didn't allow sending. Sign in to Gmail again.")
        } catch {
            return .failed("Couldn't send the mail.")
        }
    }
}

// MARK: - Outlook over Graph

extension OutlookGraphProvider: ItemSearchingProvider, ItemOpeningProvider {
    /// Graph `$search`. It cannot be combined with `$orderby`, and Graph orders the
    /// hits itself. A quote in the query would end the quoted search term.
    static func searchURL(query: String, limit: Int) -> URL? {
        let term = query.replacingOccurrences(of: "\"", with: " ")
        return MicrosoftGraph.url("/me/messages", [
            ("$search", "\"\(term)\""),
            ("$top", "\(limit)"),
            ("$select", "id,subject,from,receivedDateTime,isRead,webLink,bodyPreview"),
        ])
    }

    func searchItems(_ query: String, for instance: ConnectorInstance,
                     limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            guard let url = Self.searchURL(query: query, limit: limit) else { return [] }
            return Self.parseMessages(try await ConnectorHTTP.getJSON(url, token: token),
                                      instanceLabel: instance.displayLabel)
        }
    }

    func openItem(_ item: ConnectorItem,
                  for instance: ConnectorInstance) async -> ProviderReadOutcome<OpenedItem?> {
        await withResolvedToken(instance, empty: nil) { token in
            guard let url = Self.messageURL(id: item.id) else { return nil }
            // Graph converts the body to text itself when asked.
            let json = try await ConnectorHTTP.getJSON(
                url, token: token, headers: ["Prefer": "outlook.body-content-type=\"text\""])
            return Self.openedItem(from: json)
        }
    }

    static func messageURL(id: String) -> URL? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return MicrosoftGraph.url("/me/messages/\(encoded)", [
            ("$select", "subject,from,toRecipients,ccRecipients,replyTo,receivedDateTime,body"),
        ])
    }

    static func openedItem(from json: [String: Any]) -> OpenedItem {
        func addresses(_ value: Any?) -> String {
            let list = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
            return list.compactMap { entry -> String? in
                guard let email = entry["emailAddress"] as? [String: Any],
                      let address = email["address"] as? String else { return nil }
                let name = email["name"] as? String ?? ""
                return name.isEmpty || name == address ? address : "\(name) <\(address)>"
            }.joined(separator: ", ")
        }
        let body = json["body"] as? [String: Any]
        let content = body?["content"] as? String ?? ""
        let text = (body?["contentType"] as? String)?.lowercased() == "html"
            ? MailText.plain(fromHTML: content) : content
        return OpenedItem(
            from: addresses(json["from"]), to: addresses(json["toRecipients"]),
            cc: addresses(json["ccRecipients"]), replyTo: addresses(json["replyTo"]),
            date: ConnectorHTTP.parseISO8601(json["receivedDateTime"] as? String)
                .map(MailText.date.string(from:)) ?? "",
            subject: (json["subject"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            body: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Slack thread reply

extension SlackProvider {
    /// Where a reply to a listed Slack message goes. Nil for a row that is not a
    /// message: the channel roster the read falls back to lists bare channel ids.
    struct ReplyTarget: Equatable, Sendable {
        let channelID: String
        let threadTS: String
        /// The name the card shows, as the listing wrote it ("#launch", "DM with Sam").
        let channel: String
        let author: String
    }

    /// Reads the shapes `recentItems` writes: the id `"<channel>:<ts>"` and the
    /// detail `"<channel name> · <author>"`.
    static func replyTarget(for item: ConnectorItem) -> ReplyTarget? {
        let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let detail = item.detail.components(separatedBy: " · ")
        let name = detail.first.flatMap { $0.isEmpty ? nil : $0 } ?? parts[0]
        return ReplyTarget(
            channelID: parts[0],
            threadTS: item.threadID ?? parts[1],
            // A bare "DM" names no one, so the card shows the conversation id instead.
            channel: name == "DM" ? "DM \(parts[0])" : name,
            author: detail.dropFirst().joined(separator: " · "))
    }

    /// `chat.postMessage` into the thread. `chat:write` covers a thread reply, so the
    /// scopes the setup copy lists are enough.
    static func replyBody(channelID: String, threadTS: String, text: String) -> [String: Any] {
        ["channel": channelID, "thread_ts": threadTS, "text": text]
    }

    func reply(arguments: [String: String], instance: ConnectorInstance) async -> WriteResult {
        guard let channelID = arguments["channel_id"], let threadTS = arguments["thread_ts"],
              let text = arguments["text"], !text.isEmpty
        else { return .failed("Missing the thread or the text.") }
        let channel = arguments["channel"] ?? channelID
        let token: String
        do { token = try await CredentialStrategy.resolveAndPersist(for: instance) } catch {
            return .failed("Slack credential unusable.")
        }
        do {
            let json = try await ConnectorHTTP.postJSON(
                URL(string: "https://slack.com/api/chat.postMessage")!, token: token,
                body: Self.replyBody(channelID: channelID, threadTS: threadTS, text: text))
            try ConnectorHTTP.requireSlackOK(json)
            return .done("Replied in \(channel) on \(instance.displayLabel).")
        } catch ConnectorHTTP.Failure.badStatus(_, let detail) {
            return .failed("Slack refused: \(detail)")
        } catch ConnectorHTTP.Failure.unauthorized {
            return .failed("Slack refused: this token can't post. Add the chat:write scope, reinstall the app, then reconnect.")
        } catch {
            return .failed("Couldn't reply in Slack.")
        }
    }
}
