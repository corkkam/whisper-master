import Foundation

@testable import WhisperMaster

/// A scripted stand-in for the model: the replies in order, then nil (a dead model).
///
/// A locked box rather than a captured `var` because `AgentLoop.Generate` is
/// `@Sendable` — the loop hands the generator to a task it can abandon when the budget
/// runs out, so the call counter has to be safe to touch from there.
final class ScriptedModel: @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String]
    private var index = 0

    init(_ replies: [String]) {
        self.replies = replies
    }

    /// The generator to hand the loop.
    var generate: AgentLoop.Generate {
        { [self] _, _ in next() }
    }

    /// How many generations have been asked for.
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    private func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let reply = index < replies.count ? replies[index] : nil
        index += 1
        return reply
    }
}

/// A hand-wound clock: the loop reads it through `now`, a scripted generation advances
/// it. Locked for the same reason `ScriptedModel` is.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ start: Date) {
        date = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date += seconds
    }
}

/// Stands in for the connector router, so a write can "go through" without a network
/// call — no provider can complete a real one under `swift test`.
@MainActor
final class StubConnectorRouter: AgentToolRunning {
    private let result: ToolResult
    private(set) var calls: [ToolCall] = []

    init(_ result: ToolResult) {
        self.result = result
    }

    func run(_ call: ToolCall) async -> ToolResult {
        calls.append(call)
        return result
    }
}
