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

    /// How long a card waits before denying itself. A write must never sit indefinitely
    /// holding an automation open, and silence is not consent.
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
                // Timing out is a *denial*, never an allow — silence can't authorise a
                // write.
                self?.resolve(.denied)
            }
        }
    }

    /// The user answered on the card.
    func resolve(_ outcome: ApprovalOutcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        pending = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    /// A headless policy for automations, which have no one to ask.
    ///
    /// Denies anything without a standing grant: a scheduled task must never be the path
    /// by which an unapproved write happens, because there's nobody watching when it
    /// fires. The user grants "always allow" interactively first, and only then can an
    /// automation use it.
    static let denyUnattended: (PendingApproval) async -> ApprovalOutcome = { _ in .denied }
}
