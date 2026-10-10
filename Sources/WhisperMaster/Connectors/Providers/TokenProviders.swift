import Foundation

/// The manual-token providers: Slack, Notion, Linear, GitHub, Asana, Gmail, Drive, Zoom.
/// (Outlook and Teams sign in through Microsoft — `MicrosoftGraphProviders.swift`.)
///
/// Each is a `validate` (a real whoami, whose answer becomes the instance identity) plus
/// a `recentItems` / events read. They're grouped in one file because each is genuinely
/// ~30–80 lines of endpoint-and-JSON-shape.
///
/// **All of these authenticate with a token the user pasted, not an OAuth flow we ran.**
/// Slack, Notion, Linear and Asana all require a `client_secret` at token exchange and
/// offer no public PKCE client, so a shipping desktop binary cannot do one-click for
/// them without a broker. The user creating their own app/token is both the only honest
/// option and the most private one — the credential is theirs, scoped how they chose.
///
/// Gmail and Drive follow the same manual-token path for a different reason: Gmail's
/// read scope is Google-restricted (CASA), and Drive's one-click rides on the same
/// OAuth client we already use for Calendar — but a pasted token always works, which
/// is the openworker discipline this catalog was built around.

// MARK: - Slack

@MainActor
struct SlackProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .slack

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let token = credential["bot_token"], !token.isEmpty else {
            return .invalid("Paste a Slack token (starts with xoxb- or xoxp-).")
        }
        do {
            let json = try await ConnectorHTTP.getJSON(
                URL(string: "https://slack.com/api/auth.test")!, token: token)
            try ConnectorHTTP.requireSlackOK(json)
            let team = json["team"] as? String ?? "?"
            let user = json["user"] as? String ?? "bot"
            // `auth.test` already names the workspace this token belongs to, so record
            // it rather than making every later call re-derive it.
            let config = (json["team_id"] as? String).map { ConnectorConfig.workspace(teamID: $0) }
            return .valid(identity: "\(team) / \(user)", config: config)
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Slack rejected that token.")
        } catch {
            return .invalid("Couldn't reach Slack: \(error)")
        }
    }

    /// Recent **messages**, not channel names.
    ///
    /// The blurb promised "mentions and unreads"; the first cut listed channel names
    /// and topics, which is what a directory search returns — not what "anything new
    /// in Slack?" means. Grok/Claude connectors surface recent content. We walk the
    /// conversations the token is a member of and pull the latest history from each,
    /// so the answer is actual chat rather than a roster.
    ///
    /// **`users.conversations`, not `conversations.list`.** The list call returns every
    /// public channel in the workspace whether or not the token is in it, so the first
    /// few it handed back were usually channels a bot was never invited to, every
    /// history call answered `not_in_channel`, and the read fell through to the roster
    /// — a connected Slack that could not quote a single message.
    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            let channels = try await Self.memberConversations(token: token)
            // `updated` is the conversation record's last change; Slack gives no
            // last-message time here, so this is a heuristic, and the cap below is what
            // keeps a read inside one Tier-3 burst.
            let ordered = channels.sorted {
                (($0["updated"] as? Double) ?? 0) > (($1["updated"] as? Double) ?? 0)
            }

            var items: [ConnectorItem] = []
            var userNames: [String: String] = [:]
            let walked = ordered.prefix(Self.maxConversations)
            let perChannel = max(2, limit / max(walked.count, 1))
            for channel in walked {
                guard let channelID = channel["id"] as? String else { continue }
                var historyComponents = URLComponents(string: "https://slack.com/api/conversations.history")!
                historyComponents.queryItems = [
                    .init(name: "channel", value: channelID),
                    .init(name: "limit", value: "\(perChannel)"),
                ]
                guard let historyURL = historyComponents.url else { continue }
                // One channel refusing (missing *:history scope for its type) must not
                // blank the rest — same partial-success rule as the Google calendar
                // fan-out.
                guard let historyJSON = try? await ConnectorHTTP.getJSON(historyURL, token: token),
                      (historyJSON["ok"] as? Bool) == true
                else { continue }
                let messages = (historyJSON["messages"] as? [[String: Any]] ?? [])
                    .filter(Self.isConversation)
                // Names, not ids: "U04ABCD said…" answers nothing. Looked up once per
                // read and only for authors and mentions actually on screen.
                for id in Self.userIDs(in: messages) where userNames[id] == nil {
                    userNames[id] = await Self.userName(id, token: token)
                }
                let channelName = Self.channelLabel(channel, userNames: userNames)
                for message in messages {
                    guard let ts = message["ts"] as? String else { continue }
                    let text = Self.plainText(message["text"] as? String ?? "", userNames: userNames)
                    guard !text.isEmpty else { continue }
                    let author = (message["user"] as? String).map { userNames[$0] ?? $0 }
                        ?? (message["username"] as? String)
                        ?? (message["bot_id"] as? String).map { "bot:\($0)" }
                        ?? "someone"
                    items.append(ConnectorItem(
                        id: "\(channelID):\(ts)",
                        title: text,
                        detail: "\(channelName) · \(author)",
                        timestamp: Self.slackTimestamp(ts),
                        instanceLabel: instance.displayLabel))
                }
            }
            // Fallback: if history was empty everywhere (no *:history scope), still
            // return the channel roster so the connection is useful rather than
            // silently empty — and the detail line names that it's a directory.
            if items.isEmpty {
                return ordered.prefix(limit).compactMap { channel in
                    guard let id = channel["id"] as? String else { return nil }
                    let topic = (channel["topic"] as? [String: Any])?["value"] as? String ?? ""
                    return ConnectorItem(
                        id: id,
                        title: Self.channelLabel(channel, userNames: userNames),
                        detail: topic.isEmpty ? "channel" : topic,
                        instanceLabel: instance.displayLabel)
                }
            }
            // Newest first across every channel, *then* cut — cutting first kept
            // whichever channel happened to be walked first, however old.
            return Array(items
                .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
                .prefix(limit))
        }
    }

    /// How many conversations one read walks. Each is one `conversations.history`
    /// call, and Slack's Tier 3 allows ~50 a minute per method.
    static let maxConversations = 8

    /// Every conversation type, then public channels alone. Slack answers
    /// `missing_scope` for the **whole** call when the token lacks the read scope for
    /// any one type asked for, and the setup copy used to list only the `channels:*`
    /// scopes — so asking for DMs unconditionally failed every token made by
    /// following the instructions.
    static let conversationTypeFallbacks = ["public_channel,private_channel,mpim,im", "public_channel"]

    private static func memberConversations(token: String) async throws -> [[String: Any]] {
        var lastError: Error?
        for types in conversationTypeFallbacks {
            var components = URLComponents(string: "https://slack.com/api/users.conversations")!
            components.queryItems = [
                .init(name: "limit", value: "100"),
                .init(name: "exclude_archived", value: "true"),
                .init(name: "types", value: types),
            ]
            guard let url = components.url else { continue }
            let json = try await ConnectorHTTP.getJSON(url, token: token)
            do {
                try ConnectorHTTP.requireSlackOK(json)
                return json["channels"] as? [[String: Any]] ?? []
            } catch {
                lastError = error
                guard (json["error"] as? String) == "missing_scope" else { throw error }
            }
        }
        throw lastError ?? ConnectorHTTP.Failure.malformedResponse
    }

    /// Real conversation, not channel housekeeping (joins, topic changes, renames).
    private static func isConversation(_ message: [String: Any]) -> Bool {
        guard let subtype = message["subtype"] as? String else { return true }
        return !["channel_join", "channel_leave", "channel_topic", "channel_purpose",
                 "channel_name", "channel_archive", "channel_unarchive",
                 "group_join", "group_leave"].contains(subtype)
    }

    /// Authors and `<@U…>` mentions, in first-seen order.
    static func userIDs(in messages: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for message in messages {
            var found: [String] = []
            if let user = message["user"] as? String { found.append(user) }
            let text = message["text"] as? String ?? ""
            for match in mentionPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { found.append(String(text[range])) }
            }
            for id in found where seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    private static let mentionPattern = try! NSRegularExpression(pattern: "<@([UW][A-Z0-9]+)(?:\\|[^>]*)?>")

    /// `users.info` → the name a person would say. Nil (and the id is shown) when
    /// the token lacks `users:read`; a missing name must not fail the read.
    private static func userName(_ id: String, token: String) async -> String? {
        var components = URLComponents(string: "https://slack.com/api/users.info")!
        components.queryItems = [.init(name: "user", value: id)]
        guard let url = components.url,
              let json = try? await ConnectorHTTP.getJSON(url, token: token),
              (json["ok"] as? Bool) == true,
              let user = json["user"] as? [String: Any]
        else { return nil }
        let profile = user["profile"] as? [String: Any]
        return [profile?["display_name"], profile?["real_name"], user["real_name"], user["name"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
    }

    /// Slack's message markup as the words a person would read: `<@U1>` → `@Sam`,
    /// `<#C1|general>` → `#general`, `<https://x|label>` → `label`, `<!here>` →
    /// `@here`, and the three HTML escapes Slack applies. The model otherwise reads
    /// ids it can't resolve and quotes them back.
    static func plainText(_ text: String, userNames: [String: String] = [:]) -> String {
        let pattern = try! NSRegularExpression(pattern: "<([^<>]+)>")
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let inner = source.substring(with: match.range(at: 1))
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first ?? ""
            let label = parts.count > 1 ? parts[1] : nil
            switch target.first {
            case "@":
                let id = String(target.dropFirst())
                result += "@" + (userNames[id] ?? label ?? id)
            case "#":
                result += "#" + (label ?? String(target.dropFirst()))
            case "!":
                let command = String(target.dropFirst())
                result += label ?? (["here", "channel", "everyone"].contains(command) ? "@\(command)" : "")
            default:
                result += label ?? target
            }
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func channelLabel(_ channel: [String: Any], userNames: [String: String]) -> String {
        if let name = channel["name"] as? String, !name.isEmpty { return "#\(name)" }
        if (channel["is_im"] as? Bool) == true {
            if let user = channel["user"] as? String, let name = userNames[user] { return "DM with \(name)" }
            return "DM"
        }
        return (channel["id"] as? String) ?? "channel"
    }

    private static func slackTimestamp(_ ts: String) -> Date? {
        guard let seconds = Double(ts.split(separator: ".").first.map(String.init) ?? ts) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Linear

@MainActor
struct LinearProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .linear

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let key = credential["api_key"], !key.isEmpty else {
            return .invalid("Paste a personal API key.")
        }
        // Linear is GraphQL-only, so validation is a tiny query rather than a whoami GET.
        guard let json = await Self.graphQL("{ viewer { name email } }", key: key) else {
            return .invalid("Linear rejected that key.")
        }
        let viewer = ((json["data"] as? [String: Any])?["viewer"] as? [String: Any]) ?? [:]
        guard let email = viewer["email"] as? String ?? viewer["name"] as? String else {
            return .invalid("Linear didn't return an account.")
        }
        return .valid(identity: email)
    }

    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        let resolved: CredentialStrategy.Resolved
        do { resolved = try await CredentialStrategy.resolve(for: instance) } catch {
            return ProviderReadOutcome([], error: CredentialStrategy.connectorError(for: error))
        }
        let query = """
        { issues(first: \(min(limit, 50)), filter: { assignee: { isMe: { eq: true } }, \
        state: { type: { neq: "completed" } } }, orderBy: updatedAt) \
        { nodes { identifier title dueDate url state { name } } } }
        """
        guard let json = await Self.graphQL(query, key: resolved.token) else {
            return ProviderReadOutcome([], error: .credentialInvalid)
        }
        let nodes = (((json["data"] as? [String: Any])?["issues"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let items = nodes.compactMap { node -> ConnectorItem? in
            guard let identifier = node["identifier"] as? String,
                  let title = node["title"] as? String else { return nil }
            let state = (node["state"] as? [String: Any])?["name"] as? String ?? ""
            let due = node["dueDate"] as? String
            return ConnectorItem(
                id: identifier,
                title: "\(identifier) \(title)",
                detail: [state, due].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                url: node["url"] as? String,
                instanceLabel: instance.displayLabel)
        }
        return ProviderReadOutcome(items)
    }

    private static func graphQL(_ query: String, key: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        // Linear personal API keys go in Authorization *without* a Bearer prefix.
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["errors"] == nil
        else { return nil }
        return json
    }
}

// MARK: - GitHub

@MainActor
struct GitHubProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .github

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let token = credential["token"], !token.isEmpty else {
            return .invalid("Paste a personal access token.")
        }
        do {
            let json = try await ConnectorHTTP.getJSON(
                URL(string: "https://api.github.com/user")!, token: token,
                headers: ["X-GitHub-Api-Version": "2022-11-28"])
            guard let login = json["login"] as? String else {
                return .invalid("GitHub didn't return an account.")
            }
            return .valid(identity: login)
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("GitHub rejected that token.")
        } catch {
            return .invalid("Couldn't reach GitHub: \(error)")
        }
    }

    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            // Assigned issues *and* review requests — "what needs me on GitHub".
            // The earlier query only had assignee, so PRs waiting on a review were
            // invisible even though the blurb promised them.
            var components = URLComponents(string: "https://api.github.com/search/issues")!
            components.queryItems = [
                .init(name: "q", value: "is:open (assignee:@me OR review-requested:@me)"),
                .init(name: "per_page", value: "\(min(limit, 50))"),
                .init(name: "sort", value: "updated"),
            ]
            guard let url = components.url else { return [] }
            let json = try await ConnectorHTTP.getJSON(
                url, token: token, headers: ["X-GitHub-Api-Version": "2022-11-28"])
            let items = json["items"] as? [[String: Any]] ?? []
            return items.compactMap { item in
                guard let title = item["title"] as? String,
                      let number = item["number"] as? Int else { return nil }
                let repo = (item["repository_url"] as? String)?
                    .replacingOccurrences(of: "https://api.github.com/repos/", with: "") ?? ""
                return ConnectorItem(
                    id: "\(repo)#\(number)",
                    title: title,
                    detail: "\(repo)#\(number)",
                    timestamp: ConnectorHTTP.parseISO8601(item["updated_at"] as? String),
                    url: item["html_url"] as? String,
                    instanceLabel: instance.displayLabel)
            }
        }
    }
}

// MARK: - Notion

@MainActor
struct NotionProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .notion
    private static let version = "2022-06-28"

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let token = credential["api_token"], !token.isEmpty else {
            return .invalid("Paste an internal integration token.")
        }
        do {
            let json = try await ConnectorHTTP.getJSON(
                URL(string: "https://api.notion.com/v1/users/me")!, token: token,
                headers: ["Notion-Version": Self.version])
            let name = json["name"] as? String
                ?? (json["bot"] as? [String: Any])?["workspace_name"] as? String
            return .valid(identity: name ?? "Notion workspace")
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Notion rejected that token. Did you share pages with the integration?")
        } catch {
            return .invalid("Couldn't reach Notion: \(error)")
        }
    }

    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "page_size": min(limit, 50),
                "sort": ["direction": "descending", "timestamp": "last_edited_time"],
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ConnectorHTTP.Failure.malformedResponse }
            if http.statusCode == 401 || http.statusCode == 403 { throw ConnectorHTTP.Failure.unauthorized }
            guard (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ConnectorHTTP.Failure.badStatus(http.statusCode, "") }
            let results = json["results"] as? [[String: Any]] ?? []
            return results.compactMap { Self.item(from: $0, instanceLabel: instance.displayLabel) }
        }
    }

    /// Notion's title lives at a different path for a page than a database, and is an
    /// array of rich-text runs either way.
    private static func item(from result: [String: Any], instanceLabel: String) -> ConnectorItem? {
        guard let id = result["id"] as? String else { return nil }
        var title = "Untitled"
        if let properties = result["properties"] as? [String: Any] {
            for value in properties.values {
                if let property = value as? [String: Any],
                   let runs = property["title"] as? [[String: Any]],
                   let text = runs.compactMap({ $0["plain_text"] as? String }).first,
                   !text.isEmpty {
                    title = text
                    break
                }
            }
        } else if let runs = result["title"] as? [[String: Any]],
                  let text = runs.compactMap({ $0["plain_text"] as? String }).first {
            title = text
        }
        return ConnectorItem(
            id: id, title: title,
            detail: (result["object"] as? String) ?? "",
            timestamp: ConnectorHTTP.parseISO8601(result["last_edited_time"] as? String),
            url: result["url"] as? String,
            instanceLabel: instanceLabel)
    }
}

// MARK: - Asana

@MainActor
struct AsanaProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .asana

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let token = credential["api_token"], !token.isEmpty else {
            return .invalid("Paste a personal access token.")
        }
        do {
            let account = try await Self.me(token: token)
            guard let identity = account.identity else {
                return .invalid("Asana didn't return an account.")
            }
            // **The workspace is the point of this call, not a bonus.** Asana's task
            // endpoint rejects a query without one, so a connection saved without a
            // workspace validates green and then reads nothing forever.
            guard let workspace = account.workspaceID else {
                return .invalid("That token's account isn't in any Asana workspace.")
            }
            return .valid(identity: identity, config: .workspace(teamID: workspace))
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Asana rejected that token.")
        } catch {
            return .invalid("Couldn't reach Asana: \(error)")
        }
    }

    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            // Connections added before the workspace was ever recorded carry `.empty`,
            // so re-derive it rather than sending `workspace=` and taking a 400. One
            // extra request on a legacy instance beats a connector that is silently
            // dead until the user thinks to delete and re-add it.
            let workspace: String
            if let stored = instance.config.workspaceID, !stored.isEmpty {
                workspace = stored
            } else if let discovered = try await Self.me(token: token).workspaceID {
                workspace = discovered
            } else {
                throw ConnectorHTTP.Failure.badStatus(400, "no Asana workspace for this account")
            }

            var components = URLComponents(string: "https://app.asana.com/api/1.0/tasks")!
            components.queryItems = [
                .init(name: "assignee", value: "me"),
                .init(name: "workspace", value: workspace),
                .init(name: "completed_since", value: "now"),
                .init(name: "opt_fields", value: "name,due_on,permalink_url"),
                .init(name: "limit", value: "\(min(limit, 50))"),
            ]
            guard let url = components.url else { return [] }
            let json = try await ConnectorHTTP.getJSON(url, token: token)
            let tasks = json["data"] as? [[String: Any]] ?? []
            return tasks.compactMap { task in
                guard let gid = task["gid"] as? String, let name = task["name"] as? String else { return nil }
                return ConnectorItem(
                    id: gid, title: name,
                    detail: (task["due_on"] as? String).map { "due \($0)" } ?? "",
                    url: task["permalink_url"] as? String,
                    instanceLabel: instance.displayLabel)
            }
        }
    }

    /// `/users/me`, which answers both "who is this token" and "which workspace" in
    /// one round trip. Shared by validate and the legacy-instance repair above so the
    /// two can't read the response differently.
    private static func me(token: String) async throws -> (identity: String?, workspaceID: String?) {
        let json = try await ConnectorHTTP.getJSON(
            URL(string: "https://app.asana.com/api/1.0/users/me")!, token: token)
        let data = json["data"] as? [String: Any] ?? [:]
        let workspaces = data["workspaces"] as? [[String: Any]] ?? []
        return ((data["email"] as? String) ?? (data["name"] as? String),
                workspaces.first?["gid"] as? String)
    }
}

// MARK: - Gmail

/// Gmail over a pasted OAuth access token (or OAuth Playground token).
///
/// Featured on the product surface and first-class on Grok — but until CASA clears
/// for a managed client, the only honest path is a token the user minted themselves.
/// That path was catalogued with fields and instructions and then left without a
/// provider, so the tile read "Coming soon" while the form described a working
/// paste. Wire the whoami + unread list so the catalog entry is real.
@MainActor
struct GmailProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .gmail

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let token = credential["access_token"] ?? credential.accessToken, !token.isEmpty else {
            return .invalid("Paste a Google OAuth access token with a Gmail read scope.")
        }
        // Prefer the address the user typed (so a workspace alias sticks), then
        // fall back to the profile the token actually belongs to.
        let typed = credential["account"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let json = try await ConnectorHTTP.getJSON(
                URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!,
                token: token)
            let email = (json["emailAddress"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let identity = (typed?.isEmpty == false ? typed : nil) ?? email, !identity.isEmpty else {
                return .invalid("Gmail didn't return a mailbox address.")
            }
            return .valid(identity: identity)
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Gmail rejected that token. It needs gmail.readonly (or broader).")
        } catch {
            return .invalid("Couldn't reach Gmail: \(error)")
        }
    }

    /// Unread first, then the rest of the recent inbox — "what's in my mail" means
    /// what still needs me, not a raw chronological dump.
    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            let capped = min(limit, 25)
            // Two passes: unread first so the answer leads with what needs attention,
            // then fill with recent mail if unread alone underfills the budget.
            var collected: [ConnectorItem] = []
            var seen = Set<String>()
            for query in ["is:unread", "in:inbox"] {
                let remaining = capped - collected.count
                guard remaining > 0 else { break }
                let batch = try await Self.listMessages(
                    token: token, query: query, limit: remaining,
                    instanceLabel: instance.displayLabel)
                for item in batch where !seen.contains(item.id) {
                    seen.insert(item.id)
                    collected.append(item)
                }
            }
            return collected
        }
    }

    private static func listMessages(token: String, query: String, limit: Int,
                                     instanceLabel: String) async throws -> [ConnectorItem] {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "maxResults", value: "\(limit)"),
        ]
        guard let listURL = components.url else { return [] }
        let listJSON = try await ConnectorHTTP.getJSON(listURL, token: token)
        let stubs = listJSON["messages"] as? [[String: Any]] ?? []
        var items: [ConnectorItem] = []
        for stub in stubs.prefix(limit) {
            guard let id = stub["id"] as? String else { continue }
            // Metadata format gives headers without the body — enough for a notch
            // line and far cheaper than full format.
            guard let metaURL = URL(string:
                "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date")
            else { continue }
            guard let meta = try? await ConnectorHTTP.getJSON(metaURL, token: token) else { continue }
            let headers = ((meta["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
            func header(_ name: String) -> String {
                headers.first {
                    ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
                }?["value"] as? String ?? ""
            }
            let subject = header("Subject").trimmingCharacters(in: .whitespacesAndNewlines)
            let from = header("From").trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = (meta["snippet"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = subject.isEmpty ? (snippet.isEmpty ? "(no subject)" : snippet) : subject
            let labelIDs = meta["labelIds"] as? [String] ?? []
            let unread = labelIDs.contains("UNREAD") ? "unread · " : ""
            items.append(ConnectorItem(
                id: id,
                title: title,
                detail: "\(unread)\(from)",
                timestamp: Self.gmailDate(meta["internalDate"] as? String),
                url: "https://mail.google.com/mail/u/0/#inbox/\(id)",
                instanceLabel: instanceLabel))
        }
        return items
    }

    private static func gmailDate(_ internalDate: String?) -> Date? {
        guard let internalDate, let millis = Double(internalDate) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

// MARK: - Google Drive

@MainActor
struct GoogleDriveProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .googleDrive

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let token = credential["access_token"] ?? credential.accessToken, !token.isEmpty else {
            return .invalid("Paste a Google OAuth access token with a Drive read scope.")
        }
        let typed = credential["account"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let json = try await ConnectorHTTP.getJSON(
                URL(string: "https://www.googleapis.com/drive/v3/about?fields=user")!,
                token: token)
            let email = ((json["user"] as? [String: Any])?["emailAddress"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = ((json["user"] as? [String: Any])?["displayName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let identity = (typed?.isEmpty == false ? typed : nil)
                    ?? email ?? name, !identity.isEmpty else {
                return .invalid("Drive didn't return an account.")
            }
            return .valid(identity: identity)
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Drive rejected that token. It needs drive.readonly (or broader).")
        } catch {
            return .invalid("Couldn't reach Drive: \(error)")
        }
    }

    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                .init(name: "pageSize", value: "\(min(limit, 50))"),
                .init(name: "orderBy", value: "modifiedTime desc"),
                .init(name: "fields",
                      value: "files(id,name,mimeType,modifiedTime,webViewLink,owners,shared)"),
                // Not trashed — matching what a human means by "my recent files".
                .init(name: "q", value: "trashed = false"),
            ]
            guard let url = components.url else { return [] }
            let json = try await ConnectorHTTP.getJSON(url, token: token)
            let files = json["files"] as? [[String: Any]] ?? []
            return files.compactMap { file in
                guard let id = file["id"] as? String,
                      let name = file["name"] as? String else { return nil }
                let mime = file["mimeType"] as? String ?? ""
                let shared = (file["shared"] as? Bool) == true ? "shared · " : ""
                return ConnectorItem(
                    id: id,
                    title: name,
                    detail: "\(shared)\(Self.friendlyMIME(mime))",
                    timestamp: ConnectorHTTP.parseISO8601(file["modifiedTime"] as? String),
                    url: file["webViewLink"] as? String,
                    instanceLabel: instance.displayLabel)
            }
        }
    }

    private static func friendlyMIME(_ mime: String) -> String {
        switch mime {
        case "application/vnd.google-apps.document": return "Doc"
        case "application/vnd.google-apps.spreadsheet": return "Sheet"
        case "application/vnd.google-apps.presentation": return "Slides"
        case "application/vnd.google-apps.folder": return "Folder"
        case "application/pdf": return "PDF"
        default:
            if mime.hasPrefix("image/") { return "Image" }
            if mime.hasPrefix("video/") { return "Video" }
            if mime.isEmpty { return "File" }
            return mime.split(separator: "/").last.map(String.init) ?? "File"
        }
    }
}

// MARK: - Zoom

/// Zoom server-to-server OAuth: store account/client credentials, mint a 1h token
/// per request via `CredentialStrategy.mintedToken`. Meetings land as calendar-like
/// events so "what's my day" merges them with EventKit/Google.
@MainActor
struct ZoomProvider: EventReadingProvider, AsyncEventReadingProvider {
    static let kind: ConnectorKind = .zoom

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let accountID = credential["account_id"], !accountID.isEmpty,
              let clientID = credential["client_id"], !clientID.isEmpty,
              let clientSecret = credential["client_secret"], !clientSecret.isEmpty
        else {
            return .invalid("Paste the Account ID, Client ID and Client secret from your Zoom app.")
        }
        // Mint inline from the pasted material — `CredentialStrategy.resolve` reads
        // the Keychain by instance id, and at connect time nothing is stored yet.
        do {
            let token = try await Self.mint(accountID: accountID,
                                            clientID: clientID,
                                            clientSecret: clientSecret)
            // Server-to-server apps have no "me"; the users list confirms the
            // account answers under this token and gives us a human identity.
            var components = URLComponents(string: "https://api.zoom.us/v2/users")!
            components.queryItems = [.init(name: "page_size", value: "1")]
            guard let url = components.url else {
                return .invalid("Couldn't build the Zoom users URL.")
            }
            let json = try await ConnectorHTTP.getJSON(url, token: token)
            let firstEmail = ((json["users"] as? [[String: Any]])?.first)?["email"] as? String
            let identity = firstEmail ?? accountID
            return .valid(identity: identity, config: .account(accountID: accountID))
        } catch ConnectorHTTP.Failure.unauthorized {
            return .invalid("Zoom rejected those credentials.")
        } catch {
            return .invalid("Couldn't reach Zoom: \(error)")
        }
    }

    /// Same exchange `CredentialStrategy` uses for `.mintedToken`, kept here so
    /// validate can run before anything is in the Keychain.
    private static func mint(accountID: String, clientID: String, clientSecret: String) async throws -> String {
        var components = URLComponents(string: "https://zoom.us/oauth/token")!
        components.queryItems = [
            .init(name: "grant_type", value: "account_credentials"),
            .init(name: "account_id", value: accountID),
        ]
        guard let url = components.url else {
            throw ConnectorHTTP.Failure.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorHTTP.Failure.malformedResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ConnectorHTTP.Failure.unauthorized
        }
        guard (200..<300).contains(http.statusCode),
              let parsed = OAuthTokenResponse.parse(data)
        else {
            throw ConnectorHTTP.Failure.badStatus(
                http.statusCode, String(data: data, encoding: .utf8) ?? "mint failed")
        }
        return parsed.accessToken
    }

    /// Sync half is empty — Zoom is network-only. `DaySummaryService` uses the async
    /// path via `AsyncEventReadingProvider`.
    func todaysEvents(for instance: ConnectorInstance, now: Date) -> ProviderReadOutcome<[DayEvent]> {
        ProviderReadOutcome([])
    }

    func todaysEventsAsync(for instance: ConnectorInstance, now: Date) async -> ProviderReadOutcome<[DayEvent]> {
        let token: String
        do {
            token = try await CredentialStrategy.resolveAndPersist(for: instance)
        } catch {
            return ProviderReadOutcome([], error: CredentialStrategy.connectorError(for: error))
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return ProviderReadOutcome([])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "https://api.zoom.us/v2/users/me/meetings")!
        components.queryItems = [
            .init(name: "type", value: "scheduled"),
            .init(name: "page_size", value: "50"),
            .init(name: "from", value: String(formatter.string(from: startOfDay).prefix(10))),
            .init(name: "to", value: String(formatter.string(from: endOfDay).prefix(10))),
        ]
        // Server-to-server apps don't have a "me"; fall back to listing across the
        // account's users when /users/me/meetings 404s.
        do {
            if let url = components.url,
               let json = try? await ConnectorHTTP.getJSON(url, token: token),
               let meetings = json["meetings"] as? [[String: Any]], !meetings.isEmpty {
                return ProviderReadOutcome(Self.parseMeetings(meetings,
                                                              instanceLabel: instance.displayLabel,
                                                              dayStart: startOfDay,
                                                              dayEnd: endOfDay))
            }
            return ProviderReadOutcome(try await Self.meetingsAcrossUsers(
                token: token,
                instanceLabel: instance.displayLabel,
                dayStart: startOfDay,
                dayEnd: endOfDay,
                formatter: formatter))
        } catch let failure as ConnectorHTTP.Failure {
            return ProviderReadOutcome([], error: failure.connectorError)
        } catch {
            return ProviderReadOutcome([], error: .unreachable)
        }
    }

    private static func meetingsAcrossUsers(token: String,
                                            instanceLabel: String,
                                            dayStart: Date,
                                            dayEnd: Date,
                                            formatter: ISO8601DateFormatter) async throws -> [DayEvent] {
        var usersComponents = URLComponents(string: "https://api.zoom.us/v2/users")!
        usersComponents.queryItems = [.init(name: "page_size", value: "10")]
        guard let usersURL = usersComponents.url else { return [] }
        let usersJSON = try await ConnectorHTTP.getJSON(usersURL, token: token)
        let users = usersJSON["users"] as? [[String: Any]] ?? []
        var events: [DayEvent] = []
        for user in users.prefix(5) {
            guard let userID = user["id"] as? String else { continue }
            var meetingComponents = URLComponents(
                string: "https://api.zoom.us/v2/users/\(userID)/meetings")!
            meetingComponents.queryItems = [
                .init(name: "type", value: "scheduled"),
                .init(name: "page_size", value: "30"),
                .init(name: "from", value: String(formatter.string(from: dayStart).prefix(10))),
                .init(name: "to", value: String(formatter.string(from: dayEnd).prefix(10))),
            ]
            guard let meetingURL = meetingComponents.url,
                  let json = try? await ConnectorHTTP.getJSON(meetingURL, token: token),
                  let meetings = json["meetings"] as? [[String: Any]]
            else { continue }
            events += parseMeetings(meetings, instanceLabel: instanceLabel,
                                    dayStart: dayStart, dayEnd: dayEnd)
        }
        return events.sorted { $0.start < $1.start }
    }

    private static func parseMeetings(_ meetings: [[String: Any]],
                                      instanceLabel: String,
                                      dayStart: Date,
                                      dayEnd: Date) -> [DayEvent] {
        meetings.compactMap { meeting -> DayEvent? in
            guard let id = meeting["id"].map({ "\($0)" }),
                  let topic = meeting["topic"] as? String,
                  let startString = meeting["start_time"] as? String,
                  let start = ConnectorHTTP.parseISO8601(startString)
            else { return nil }
            // Keep today's slice only — Zoom's from/to is date-granular and can
            // spill adjacent days depending on the account timezone.
            guard start >= dayStart && start < dayEnd else { return nil }
            let minutes = (meeting["duration"] as? Int) ?? 30
            let end = start.addingTimeInterval(TimeInterval(max(minutes, 1) * 60))
            let join = meeting["join_url"] as? String ?? ""
            return DayEvent(
                id: "zoom-\(id)",
                title: topic,
                start: start,
                end: end,
                isAllDay: false,
                calendarTitle: join.isEmpty ? "Zoom" : "Zoom · join link",
                sourceTitle: "Zoom",
                instanceLabel: instanceLabel)
        }
    }
}

// MARK: - Shared resolve-then-read

extension ItemReadingProvider {
    /// Resolve the credential, run `body`, and map every failure onto the instance's
    /// error state. Persists a refreshed credential exactly once.
    ///
    /// Errors are *returned*, never thrown out of a fan-out: one broken connector must
    /// not take down a whole answer, but it must not vanish silently either.
    func withResolvedToken(
        _ instance: ConnectorInstance,
        _ body: (String) async throws -> [ConnectorItem]
    ) async -> ProviderReadOutcome<[ConnectorItem]> {
        let resolved: CredentialStrategy.Resolved
        do {
            resolved = try await CredentialStrategy.resolve(for: instance)
        } catch {
            return ProviderReadOutcome([], error: CredentialStrategy.connectorError(for: error))
        }
        if let updated = resolved.updatedCredential {
            _ = ConnectorCredentials.save(updated, for: instance.id)
        }
        do {
            return ProviderReadOutcome(try await body(resolved.token))
        } catch let failure as ConnectorHTTP.Failure {
            return ProviderReadOutcome([], error: failure.connectorError)
        } catch {
            return ProviderReadOutcome([], error: .credentialInvalid)
        }
    }
}

extension ConnectorConfig {
    /// Asana and Slack both key their reads on a workspace/team id.
    var workspaceID: String? {
        if case let .workspace(teamID) = self { return teamID }
        return nil
    }
}
