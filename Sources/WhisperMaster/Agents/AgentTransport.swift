import Foundation

/// What the surface needs from any coding-agent server: whether it answered, and the
/// live sessions as the notch reads them.
///
/// Extracted so `AgentSurfaceController` can hold kunai and Shed at once. kunai keeps
/// its richer path (sockets, fleet, attach) and conforms through the thin extension
/// below; Shed has no per-session socket, so this is all it needs.
protocol AgentTransport: Sendable {
    var isReachable: Bool { get async }
    func agentSessions() async -> [AgentSession]
}

extension KunaiRESTClient: AgentTransport {
    func agentSessions() async -> [AgentSession] {
        await sessions().map { AgentSession(meta: $0) }
    }
}
