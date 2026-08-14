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

/// The native twin of `ScriptedModel`: scripts the model's **native** tool-calling
/// generator (`AgentLoop.GenerateNative`), so the loop's native branch is testable
/// with no MLX — the same reason `ScriptedModel` exists for the hand-rolled branch.
///
/// It also records the tool schemas it was handed on the last call, so a test can
/// assert the loop rendered schemas rather than the plain-line tool list.
final class ScriptedNativeModel: @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String]
    private var index = 0
    private var lastSchemas: [String] = []

    init(_ replies: [String]) {
        self.replies = replies
    }

    /// The native generator to hand the loop.
    var generate: AgentLoop.GenerateNative {
        { [self] _, schemas in record(schemas); return next() }
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    var schemas: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lastSchemas
    }

    private func record(_ schemas: [String]) {
        lock.lock()
        defer { lock.unlock() }
        lastSchemas = schemas
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
    /// Runs before the result is handed back — where a test winds a `TestClock`
    /// forward to give the call a duration it can then assert on.
    private let whileRunning: () -> Void
    private(set) var calls: [ToolCall] = []

    init(_ result: ToolResult, whileRunning: @escaping () -> Void = {}) {
        self.result = result
        self.whileRunning = whileRunning
    }

    func run(_ call: ToolCall) async -> ToolResult {
        calls.append(call)
        whileRunning()
        return result
    }
}
