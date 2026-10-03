import Foundation

/// Outlook and Teams over Microsoft Graph, authenticated by the app's own Microsoft
/// sign-in (`OAuthPKCEFlow.authorizeMicrosoft`, a refreshable grant).
///
/// One file because both are the same API, the same `/me`, and the same date and
/// HTML quirks; the providers themselves are a few endpoints each.

// MARK: - Shared Graph plumbing

enum MicrosoftGraph {
    static let base = "https://graph.microsoft.com/v1.0"

    static func url(_ path: String, _ query: [(String, String)] = []) -> URL? {
        var components = URLComponents(string: base + path)
        if !query.isEmpty { components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return components?.url
    }

    /// Who the token belongs to. `mail` is empty on some work accounts that have no
    /// mailbox licence, so `userPrincipalName` (always an address-shaped sign-in name)
    /// is the fallback rather than the display name, which isn't unique.
    struct Me: Equatable, Sendable {
        let id: String
        let identity: String
        let displayName: String
    }

    static func me(token: String) async throws -> Me {
        guard let url = url("/me", [("$select", "id,mail,userPrincipalName,displayName")]) else {
            throw ConnectorHTTP.Failure.malformedResponse
        }
        let json = try await ConnectorHTTP.getJSON(url, token: token)
        guard let me = parseMe(json) else { throw ConnectorHTTP.Failure.malformedResponse }
        return me
    }

    static func parseMe(_ json: [String: Any]) -> Me? {
        let mail = (json["mail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let upn = (json["userPrincipalName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity = [mail, upn].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        return Me(id: json["id"] as? String ?? "",
                  identity: identity,
                  displayName: json["displayName"] as? String ?? "")
    }

    /// The access token in a credential, refreshed first when it has expired — the
    /// connect-time form, where there is no instance id to persist under yet. Same
    /// shape as `GoogleCalendarProvider.validate`.
    static func token(from credential: ConnectorCredential) async -> (token: String?, failure: ValidationResult?) {
        do {
            return (try await CredentialStrategy.refreshedIfNeeded(credential).token, nil)
        } catch CredentialStrategy.ResolveError.noCredential {
            return (nil, .invalid("No access token on this connection."))
        } catch {
            return (nil, .invalid("This connection has expired. Sign in to Microsoft again."))
        }
    }

    // MARK: Dates

    /// A Graph `dateTimeTimeZone` read in **UTC** (every read here sends
    /// `Prefer: outlook.timezone="UTC"`). Graph writes seven fractional digits and no
    /// offset — `2026-10-04T09:00:00.0000000` — which `ISO8601DateFormatter` refuses,
    /// so the seconds-precision prefix is parsed instead.
    ///
    /// An all-day event is a *date*, not an instant: Graph reports it as midnight in
    /// the requested zone, and reading that as UTC midnight would put it on the
    /// previous day everywhere west of Greenwich. So its date is taken as a local day.
    static func date(_ slot: [String: Any]?, isAllDay: Bool, timeZone: TimeZone = .current) -> Date? {
        guard let raw = slot?["dateTime"] as? String, raw.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if isAllDay {
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = timeZone
            return formatter.date(from: String(raw.prefix(10)))
        }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: String(raw.prefix(19)))
    }

    /// The inverse, for a write: a UTC wall-clock time with no offset, sent beside
    /// `"timeZone": "UTC"`. Graph rejects an offset inside `dateTime`.
    static func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    static let utcPreference = ["Prefer": "outlook.timezone=\"UTC\""]

    // MARK: Text

    /// A Teams message body as one plain line. Bodies are HTML (`<p>`, `<at>`
    /// mentions, `<attachment>`), and handing markup to the model costs tokens it
    /// then quotes back at the user.
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Outlook (mail + calendar)

/// Outlook signed in through Microsoft: the inbox and the default calendar.
///
/// The **other** provider for the `.outlook` kind — an instance added through macOS
/// Calendar is `EventKitCalendarProvider`'s, and its config (`.calendars`) is what
/// tells the two apart, exactly as for Google Calendar.
@MainActor
struct OutlookGraphProvider: ItemReadingProvider, EventReadingProvider, AsyncEventReadingProvider {
    static let kind: ConnectorKind = .outlook

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        let resolved = await MicrosoftGraph.token(from: credential)
        guard let token = resolved.token else { return resolved.failure ?? .invalid("No access token.") }
        do {
            return .valid(identity: try await MicrosoftGraph.me(token: token).identity)
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Microsoft rejected the sign-in.")
        } catch {
            return .invalid("Couldn't reach Microsoft: \(error)")
        }
    }

    // MARK: Mail

    /// Unread first, then the rest of the inbox — the same reading of "what's in my
    /// mail" as Gmail. Two list calls and no per-message fetch: Graph returns subject,
    /// sender and preview in the list itself.
    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            let capped = min(limit, 25)
            let select = "id,subject,from,receivedDateTime,isRead,webLink,bodyPreview"
            // Graph refuses `$orderby` on a property the `$filter` doesn't lead with
            // ("InefficientFilter"), hence the always-true date clause first.
            let passes: [[(String, String)]] = [
                [("$filter", "receivedDateTime ge 1970-01-01T00:00:00Z and isRead eq false")],
                [],
            ]
            var collected: [ConnectorItem] = []
            var seen = Set<String>()
            for pass in passes {
                let remaining = capped - collected.count
                guard remaining > 0 else { break }
                guard let url = MicrosoftGraph.url("/me/mailFolders/inbox/messages", pass + [
                    ("$orderby", "receivedDateTime desc"),
                    ("$top", "\(remaining)"),
                    ("$select", select),
                ]) else { continue }
                let json = try await ConnectorHTTP.getJSON(url, token: token)
                for item in Self.parseMessages(json, instanceLabel: instance.displayLabel)
                where seen.insert(item.id).inserted {
                    collected.append(item)
                }
            }
            return collected
        }
    }

    static func parseMessages(_ json: [String: Any], instanceLabel: String) -> [ConnectorItem] {
        let messages = json["value"] as? [[String: Any]] ?? []
        return messages.compactMap { message in
            guard let id = message["id"] as? String else { return nil }
            let subject = (message["subject"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (message["bodyPreview"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let sender = (message["from"] as? [String: Any])?["emailAddress"] as? [String: Any]
            let from = (sender?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? sender?["address"] as? String ?? ""
            let unread = (message["isRead"] as? Bool) == false ? "unread · " : ""
            return ConnectorItem(
                id: id,
                title: subject.isEmpty ? (preview.isEmpty ? "(no subject)" : preview) : subject,
                detail: "\(unread)\(from)",
                timestamp: ConnectorHTTP.parseISO8601(message["receivedDateTime"] as? String),
                url: message["webLink"] as? String,
                instanceLabel: instanceLabel)
        }
    }

    // MARK: Calendar

    /// Network-only; `DaySummaryService` takes the async path below.
    func todaysEvents(for instance: ConnectorInstance, now: Date) -> ProviderReadOutcome<[DayEvent]> {
        ProviderReadOutcome([])
    }

    /// The day around `now` from the default calendar, recurrences expanded —
    /// `calendarView`, not `events`, which lists a weekly meeting once at its first
    /// occurrence.
    func todaysEventsAsync(for instance: ConnectorInstance, now: Date) async -> ProviderReadOutcome<[DayEvent]> {
        let token: String
        do {
            token = try await CredentialStrategy.resolveAndPersist(for: instance)
        } catch {
            return ProviderReadOutcome([], error: CredentialStrategy.connectorError(for: error))
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return ProviderReadOutcome([])
        }
        let iso = ISO8601DateFormatter()
        guard let url = MicrosoftGraph.url("/me/calendarView", [
            ("startDateTime", iso.string(from: dayStart)),
            ("endDateTime", iso.string(from: dayEnd)),
            ("$orderby", "start/dateTime"),
            ("$top", "50"),
            ("$select", "id,subject,start,end,isAllDay,isCancelled,location,onlineMeeting,webLink"),
        ]) else { return ProviderReadOutcome([]) }
        do {
            let json = try await ConnectorHTTP.getJSON(url, token: token, headers: MicrosoftGraph.utcPreference)
            return ProviderReadOutcome(Self.parseEvents(json, instanceLabel: instance.displayLabel))
        } catch let failure as ConnectorHTTP.Failure {
            return ProviderReadOutcome([], error: failure.connectorError)
        } catch {
            return ProviderReadOutcome([], error: .unreachable)
        }
    }

    static func parseEvents(_ json: [String: Any],
                            instanceLabel: String,
                            timeZone: TimeZone = .current) -> [DayEvent] {
        let items = json["value"] as? [[String: Any]] ?? []
        return items.compactMap { item -> DayEvent? in
            guard (item["isCancelled"] as? Bool) != true else { return nil }
            let isAllDay = (item["isAllDay"] as? Bool) == true
            guard let start = MicrosoftGraph.date(item["start"] as? [String: Any], isAllDay: isAllDay, timeZone: timeZone),
                  let end = MicrosoftGraph.date(item["end"] as? [String: Any], isAllDay: isAllDay, timeZone: timeZone)
            else { return nil }
            let location = (item["location"] as? [String: Any])?["displayName"] as? String
            let joinURL = (item["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String
            return DayEvent(
                id: "outlook-\(item["id"] as? String ?? UUID().uuidString)",
                title: (item["subject"] as? String ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines),
                start: start,
                end: end,
                isAllDay: isAllDay,
                calendarTitle: location ?? "",
                sourceTitle: "Outlook",
                instanceLabel: instanceLabel,
                joinURL: ConferenceLink.find(url: joinURL, location: location))
        }
        .sorted { $0.start < $1.start }
    }
}

extension OutlookGraphProvider: WriteCapableProvider {
    func performWrite(tool: String,
                      arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        guard tool == "create_calendar_event" else { return .failed("Outlook can't do \(tool).") }
        // `start`/`end` are stamped by `ToolRouter.resolveWriteTimes`, never by the model.
        guard let title = arguments["title"],
              let start = ConnectorHTTP.parseISO8601(arguments["start"]),
              let end = ConnectorHTTP.parseISO8601(arguments["end"])
        else { return .failed("Missing title or time.") }
        let token: String
        do { token = try await CredentialStrategy.resolveAndPersist(for: instance) } catch {
            return .failed("Microsoft credential unusable.")
        }
        guard let url = MicrosoftGraph.url("/me/events") else { return .failed("Bad events URL.") }
        do {
            _ = try await ConnectorHTTP.postJSON(url, token: token, body: [
                "subject": title,
                "start": ["dateTime": MicrosoftGraph.dateTimeString(start), "timeZone": "UTC"],
                "end": ["dateTime": MicrosoftGraph.dateTimeString(end), "timeZone": "UTC"],
            ])
            return .done("Added \"\(title)\" to \(instance.displayLabel).")
        } catch ConnectorHTTP.Failure.badStatus(_, let detail) {
            return .failed("Outlook refused: \(detail.prefix(200))")
        } catch ConnectorHTTP.Failure.unauthorized {
            // 403 here is most often a grant made before calendar write was asked for.
            return .failed("Outlook didn't allow adding events. Sign in to Microsoft again.")
        } catch {
            return .failed("Couldn't create the event.")
        }
    }
}

// MARK: - Teams

/// Microsoft Teams chats: the recent 1:1 and group conversations, and posting to one.
///
/// Chats, not channels. Reading channel messages needs `ChannelMessage.Read.All`,
/// which only a tenant administrator can grant — asking for it would stop most work
/// accounts at a consent wall, so the connector is the part every user can grant.
@MainActor
struct TeamsProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .teams

    /// Proves the grant *and* that Teams chats answer for it. `/me` alone succeeds for
    /// an account with no Teams licence, which would save a connection whose every
    /// read then fails.
    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        let resolved = await MicrosoftGraph.token(from: credential)
        guard let token = resolved.token else { return resolved.failure ?? .invalid("No access token.") }
        let me: MicrosoftGraph.Me
        do {
            me = try await MicrosoftGraph.me(token: token)
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Microsoft rejected the sign-in.")
        } catch {
            return .invalid("Couldn't reach Microsoft: \(error)")
        }
        do {
            guard let url = MicrosoftGraph.url("/me/chats", [("$top", "1")]) else {
                return .invalid("Couldn't build the Teams URL.")
            }
            _ = try await ConnectorHTTP.getJSON(url, token: token)
            return .valid(identity: me.identity)
        } catch ConnectorHTTP.Failure.transport(let detail) {
            return .invalid("Couldn't reach Teams: \(detail)")
        } catch {
            return .invalid("\(me.identity) has no Teams chats to read. Teams needs a work or school account with Teams turned on.")
        }
    }

    /// Recent chats, newest message first, one line per chat: what was last said, by
    /// whom, where. One list call carries every preview; a chat with no topic (every
    /// 1:1) costs one members call to be named, because "Chat" is not a name anybody
    /// asks about.
    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            let me = try await MicrosoftGraph.me(token: token)
            let chats = try await Self.listChats(token: token, top: min(limit, 20), withPreview: true)
            var items: [ConnectorItem] = []
            for chat in chats {
                guard let preview = chat["lastMessagePreview"] as? [String: Any],
                      let item = await Self.item(chat: chat, preview: preview, me: me, token: token,
                                                 instanceLabel: instance.displayLabel)
                else { continue }
                items.append(item)
            }
            return items
        }
    }

    private static func listChats(token: String, top: Int, withPreview: Bool) async throws -> [[String: Any]] {
        var query: [(String, String)] = [("$top", "\(min(max(top, 1), 50))")]
        if withPreview {
            query += [("$expand", "lastMessagePreview"),
                      ("$orderby", "lastMessagePreview/createdDateTime desc")]
        }
        guard let url = MicrosoftGraph.url("/me/chats", query) else { return [] }
        let json = try await ConnectorHTTP.getJSON(url, token: token)
        return json["value"] as? [[String: Any]] ?? []
    }

    private static func item(chat: [String: Any],
                             preview: [String: Any],
                             me: MicrosoftGraph.Me,
                             token: String,
                             instanceLabel: String) async -> ConnectorItem? {
        guard let id = chat["id"] as? String,
              (preview["isDeleted"] as? Bool) != true,
              (preview["messageType"] as? String ?? "message") == "message"
        else { return nil }
        let body = preview["body"] as? [String: Any]
        let content = body?["content"] as? String ?? ""
        let text = (body?["contentType"] as? String) == "html"
            ? MicrosoftGraph.plainText(fromHTML: content)
            : content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let sender = ((preview["from"] as? [String: Any])?["user"] as? [String: Any])?["displayName"] as? String
        let name = await chatName(chat, me: me, token: token)
        return ConnectorItem(
            id: "\(id):\(preview["id"] as? String ?? "")",
            title: text,
            detail: [name, sender].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            timestamp: ConnectorHTTP.parseISO8601(preview["createdDateTime"] as? String),
            url: chat["webUrl"] as? String,
            instanceLabel: instanceLabel)
    }

    /// The topic when the chat has one, else the other people in it.
    private static func chatName(_ chat: [String: Any], me: MicrosoftGraph.Me, token: String) async -> String {
        if let topic = (chat["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !topic.isEmpty { return topic }
        guard let id = chat["id"] as? String,
              let members = try? await memberNames(chatID: id, excluding: me, token: token),
              !members.isEmpty
        else { return "Chat" }
        return members.joined(separator: ", ")
    }

    private static func memberNames(chatID: String, excluding me: MicrosoftGraph.Me,
                                    token: String) async throws -> [String] {
        let encoded = chatID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chatID
        guard let url = MicrosoftGraph.url("/chats/\(encoded)/members") else { return [] }
        let json = try await ConnectorHTTP.getJSON(url, token: token)
        return parseMemberNames(json, excludingUserID: me.id)
    }

    static func parseMemberNames(_ json: [String: Any], excludingUserID: String) -> [String] {
        (json["value"] as? [[String: Any]] ?? []).compactMap { member in
            guard (member["userId"] as? String) != excludingUserID,
                  let name = member["displayName"] as? String, !name.isEmpty else { return nil }
            return name
        }
    }

    // MARK: Addressing a chat

    /// Which chat a spoken name means. **Refuses rather than guesses**: posting to the
    /// wrong person is the one outcome worse than not posting, so a name that fits two
    /// chats is sent back to be said in full, and a partial match is only taken when
    /// it is the only one.
    ///
    /// Order of trust: an exact chat name (topic, or the full member list), then a
    /// member's full name, then a member's first name, then a substring of a name.
    static func resolveChat(_ spoken: String,
                            in chats: [(id: String, name: String, members: [String])]) -> ChatResolution {
        let target = spoken.trimmingCharacters(in: CharacterSet(charactersIn: "#@ ").union(.whitespacesAndNewlines))
            .lowercased()
        guard !target.isEmpty else { return .notFound }
        let rules: [((id: String, name: String, members: [String])) -> Bool] = [
            { $0.name.lowercased() == target },
            { $0.members.contains { $0.lowercased() == target } },
            { $0.members.contains { $0.split(separator: " ").first.map(String.init)?.lowercased() == target } },
            { $0.name.lowercased().contains(target) },
        ]
        for rule in rules {
            let hits = chats.filter(rule)
            if hits.count == 1, let hit = hits.first { return .found(id: hit.id, name: hit.name) }
            if hits.count > 1 { return .ambiguous(hits.map(\.name)) }
        }
        return .notFound
    }

    enum ChatResolution: Equatable {
        case found(id: String, name: String)
        case ambiguous([String])
        case notFound
    }
}

extension TeamsProvider: WriteCapableProvider {
    func performWrite(tool: String,
                      arguments: [String: String],
                      instance: ConnectorInstance) async -> WriteResult {
        guard tool == "send_message" else { return .failed("Teams can't do \(tool).") }
        guard let spoken = arguments["channel"], let text = arguments["text"] else {
            return .failed("Missing chat or text.")
        }
        let token: String
        do { token = try await CredentialStrategy.resolveAndPersist(for: instance) } catch {
            return .failed("Microsoft credential unusable.")
        }
        do {
            let me = try await MicrosoftGraph.me(token: token)
            var chats: [(id: String, name: String, members: [String])] = []
            for chat in try await Self.listChats(token: token, top: 50, withPreview: false) {
                guard let id = chat["id"] as? String else { continue }
                let topic = (chat["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Members are fetched only for a chat with no topic, so a named group
                // costs nothing and a 1:1 costs one call.
                let members = topic.isEmpty
                    ? ((try? await Self.memberNames(chatID: id, excluding: me, token: token)) ?? [])
                    : []
                chats.append((id, topic.isEmpty ? members.joined(separator: ", ") : topic, members))
            }
            switch Self.resolveChat(spoken, in: chats) {
            case .notFound:
                return .failed("No Teams chat matches \"\(spoken)\". Teams can post to an existing chat only.")
            case .ambiguous(let names):
                return .failed("More than one Teams chat matches \"\(spoken)\": \(names.prefix(4).joined(separator: "; ")). Say the full name.")
            case .found(let id, let name):
                let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
                guard let url = MicrosoftGraph.url("/chats/\(encoded)/messages") else {
                    return .failed("Bad chat id.")
                }
                _ = try await ConnectorHTTP.postJSON(url, token: token, body: [
                    "body": ["contentType": "text", "content": text],
                ])
                return .done("Posted to \(name) on \(instance.displayLabel).")
            }
        } catch ConnectorHTTP.Failure.badStatus(_, let detail) {
            return .failed("Teams refused: \(detail.prefix(200))")
        } catch ConnectorHTTP.Failure.unauthorized {
            return .failed("Teams didn't allow that. Sign in to Microsoft again.")
        } catch {
            return .failed("Couldn't post to Teams.")
        }
    }
}
