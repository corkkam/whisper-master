import Foundation
import Observation

/// Holds the one write currently awaiting the user, and hands the answer back to the
/// suspended tool call.
///
/// One at a time on purpose: the notch shows a single band, and a queue of consent cards
/// is a UI that trains people to click through without reading. A second request while
/// one is up is denied rather than queued.
@MainActor
@Observable
final class ApprovalCoordinator {
    /// The card the notch is showing, if any.
    private(set) var pending: PendingApproval?

    /// Resolves the suspended `requestApproval` call.
    private var continuation: CheckedContinuation<ApprovalOutcome, Never>?

    /// How long a card waits before denying itself. A write must never sit
    /// indefinitely holding the agent loop open, and silence is not consent.
    var timeout: TimeInterval = 60
    private var timeoutTask: Task<Void, Never>?

    /// Ask the user. Suspends until they answer, the card times out, or it's refused
    /// because another is already up.
    func request(_ approval: PendingApproval) async -> ApprovalOutcome {
        // Never queue: an unread second card is worse than a denial the caller can report.
        guard pending == nil else { return .denied }

        return await withCheckedContinuation { continuation in
            self.pending = approval
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.timeout ?? 60))
                guard !Task.isCancelled else { return }
                // Timing out never authorises — silence can't consent to a write — but
                // it is reported as itself rather than as a denial, so the tool result
                // and the trace can say which of the two happened. See
                // `ApprovalOutcome.timedOut`.
                self?.resolve(.timedOut)
            }
        }
    }

    /// The one place a card ends, so every outcome is counted exactly once. Called
    /// with the user's own choice from the card, and with `.timedOut` by the timer.
    ///
    /// The distinction is load-bearing for the design as well as for the copy: a card
    /// nobody answers is a card in the wrong place, while a "No" is the consent model
    /// working.
    func resolve(_ outcome: ApprovalOutcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        // Read before `pending` is cleared. The tool name is a fixed catalog string,
        // never an argument — the same rule the notch caption follows, and for the
        // same reason: the arguments are the user's dictated content.
        let tool = pending?.tool
        pending = nil
        continuation?.resume(returning: outcome)
        continuation = nil

        if let tool {
            let decision: AnalyticsEvent.ApprovalDecision
            switch outcome {
            case .allowedOnce: decision = .once
            case .allowedAlways: decision = .always
            case .denied: decision = .denied
            case .timedOut: decision = .timedOut
            }
            Analytics.shared.send(.approvalDecided(tool: tool, decision: decision))
        }
    }

    #if DEBUG
    /// Puts a card up with nobody suspended behind it — the headless snapshot
    /// renderer's only way in, since `request` suspends until the card is answered
    /// and `ImageRenderer` draws synchronously right after. Never call this from the
    /// running app: a card seeded this way answers no tool call, so resolving it
    /// silently does nothing.
    func seedPendingForSnapshot(_ approval: PendingApproval) { pending = approval }
    #endif
}
