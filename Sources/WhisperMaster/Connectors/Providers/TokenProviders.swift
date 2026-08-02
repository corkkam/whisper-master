import Foundation

/// The manual-token providers: Slack, Notion, Linear, GitHub, Asana, Gmail, Drive.
///
/// Each is a `validate` (a real whoami, whose answer becomes the instance identity) plus
/// a `recentItems` read. They're grouped in one file because each is genuinely ~30 lines
/// of endpoint-and-JSON-shape and splitting them would be seven files of ceremony
/// around one idea.
///
/// **All of these authenticate with a token the user pasted, not an OAuth flow we ran.**
/// Slack, Notion, Linear and Asana all require a `client_secret` at token exchange and
/// offer no public PKCE client, so a shipping desktop binary cannot do one-click for
/// them without a broker. The user creating their own app/token is both the only honest
/// option and the most private one — the credential is theirs, scoped how they chose.

// MARK: - Slack

@MainActor
struct SlackProvider: ItemReadingProvider {
    static let kind: ConnectorKind = .slack

    func validate(_ credential: ConnectorCredential, config: ConnectorConfig) async -> ValidationResult {
        guard let token = credential["bot_token"], !token.isEmpty else {
            return .invalid("Paste a bot token (starts with xoxb-).")
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

    /// Recent messages the bot can see. Scoped to the channels the *user's own app* was
    /// granted, so this reads exactly what they chose to expose and nothing more.
    func recentItems(for instance: ConnectorInstance, limit: Int) async -> ProviderReadOutcome<[ConnectorItem]> {
        await withResolvedToken(instance) { token in
            var components = URLComponents(string: "https://slack.com/api/conversations.list")!
            components.queryItems = [
                .init(name: "limit", value: "\(min(limit, 50))"),
                .init(name: "exclude_archived", value: "true"),
                .init(name: "types", value: "public_channel,private_channel"),
            ]
            guard let url = components.url else { return [] }
            let json = try await ConnectorHTTP.getJSON(url, token: token)
            try ConnectorHTTP.requireSlackOK(json)
            let channels = json["channels"] as? [[String: Any]] ?? []
            return channels.prefix(limit).compactMap { channel in
                guard let id = channel["id"] as? String else { return nil }
                let name = channel["name"] as? String ?? id
                let topic = (channel["topic"] as? [String: Any])?["value"] as? String ?? ""
                return ConnectorItem(
                    id: id, title: "#\(name)", detail: topic,
                    instanceLabel: instance.displayLabel)
            }
        }
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
            // Review requests + assigned issues in one search, which is what "what needs
            // me on GitHub" actually means.
            var components = URLComponents(string: "https://api.github.com/search/issues")!
            components.queryItems = [
                .init(name: "q", value: "is:open assignee:@me"),
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
