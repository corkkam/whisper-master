import Foundation

/// Reads `<project>/.crew/crew.json` for the names, roles and hues of a project's
/// agents. It keeps the parsed roster until the file's modification date or size
/// changes. Not thread safe: `CrewReader` owns one, off the main actor.
final class CrewRoster {
    struct Member: Decodable, Equatable, Sendable {
        var id: String
        var role: String?
        var name: String?
        var hue: Int?
        var componentDir: String?

        enum CodingKeys: String, CodingKey {
            case id, role, name, hue
            case componentDir = "component_dir"
        }
    }

    /// The parsed agents of one project. A value, so it can cross to the main actor.
    struct Members: Equatable, Sendable {
        var byID: [String: Member] = [:]

        /// The face identity of an agent. Nil for a helper: the rail does not show one.
        /// An unknown project or agent still gets a face: its id as the name, role component.
        func identity(agent: String) -> AgentFaceIdentity? {
            guard let member = byID[agent] else {
                return AgentFaceIdentity(name: agent, role: .component)
            }
            let name = member.name.flatMap { $0.isEmpty ? nil : $0 } ?? member.id
            switch member.role ?? "" {
            case "helper":
                return nil
            case "custom":
                return AgentFaceIdentity(
                    name: name, role: .component, hueIndex: member.hue, componentName: name)
            case "component":
                let folder = member.componentDir.map { ($0 as NSString).lastPathComponent }
                return AgentFaceIdentity(
                    name: name, role: .component, hueIndex: member.hue,
                    componentName: folder.flatMap { $0.isEmpty ? nil : $0 } ?? name)
            default:
                let role = AgentFaceRole(rawValue: member.role ?? "") ?? .component
                return AgentFaceIdentity(name: name, role: role, hueIndex: member.hue)
            }
        }

        func isLead(agent: String) -> Bool { byID[agent]?.role == "lead" }

        /// The agent whose role is `lead`. The smallest id wins if there are several.
        var leadID: String? { byID.values.filter { $0.role == "lead" }.map(\.id).min() }
    }

    private struct File: Decodable {
        var agents: [Member]?
    }

    private struct Cached {
        var modified: Date?
        var size: Int?
        var members: Members
    }

    private var cache: [String: Cached] = [:]

    func identity(project: String, agent: String) -> AgentFaceIdentity? {
        members(project: project).identity(agent: agent)
    }

    func isLead(project: String, agent: String) -> Bool {
        members(project: project).isLead(agent: agent)
    }

    /// Stats the file on each call and parses it again only when it changed.
    func members(project: String) -> Members {
        let path = (project as NSString).appendingPathComponent(".crew/crew.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue
        if let hit = cache[project], hit.modified == modified, hit.size == size {
            return hit.members
        }
        var members = Members()
        if attributes != nil,
           let data = FileManager.default.contents(atPath: path),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            for m in file.agents ?? [] { members.byID[m.id] = m }
        }
        cache[project] = Cached(modified: modified, size: size, members: members)
        return members
    }
}
