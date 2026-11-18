import Foundation

/// The last answered command, kept for a short while so the next chord capture can
/// refer to it: "what's on tomorrow", then "and Friday?".
///
/// **Memory only, and time only.** Nothing here is written to disk, it expires
/// `duration` after the answer whatever happens in between, the next capture takes
/// it (so a new run always replaces it), and sign-out clears it. It is built from
/// `CommandAgentService.Run.storableAnswer`, so an answer that repeats 40 or more
/// characters of the selection in a row arrives as the placeholder. A summary or a
/// translation of the selection can still reach it — the same limit the answer log
/// has. A run that read untrusted text (mail, messages, a selection) hands its taint
/// to the follow-up: the answer it carries may hold that text's words.
///
/// The view model owns the one instance; `CommandAgentService` is built per run and
/// only receives the digest, which the loop sends as an earlier turn of the
/// conversation rather than as part of its rules.
@MainActor
final class FollowUpWindow {
    /// What the next run is given: the last question and answer, each on one line,
    /// together at most `FollowUpWindow.limit` characters.
    struct Digest: Equatable, Sendable {
        let question: String
        let answer: String
        let tainted: Bool

        /// The question gets a third at most, so a long question cannot push the
        /// answer out.
        init(question: String, answer: String, tainted: Bool) {
            let asked = Self.oneLine(question, limit: FollowUpWindow.limit / 3)
            self.question = asked
            self.answer = Self.oneLine(answer, limit: FollowUpWindow.limit - asked.count)
            self.tainted = tainted
        }

        private static func oneLine(_ text: String, limit: Int) -> String {
            let flat = text.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return flat.count > limit ? String(flat.prefix(max(0, limit - 1))) + "\u{2026}" : flat
        }
    }

    nonisolated static let duration: TimeInterval = 120
    nonisolated static let limit = 400

    private var held: (digest: Digest, at: Date)?
    /// Moves on every `clear`. A run reads it when it starts and hands it back to
    /// `remember`, so a run still in flight at sign-out cannot leave its answer for
    /// the next account.
    private(set) var generation = 0

    /// Keep `run`'s answer for the next capture, or forget the last one when `run`
    /// answered nothing. A run that filed or sent something is a receipt, not an
    /// answer, and is not offered. A run that began before the last `clear` changes
    /// nothing.
    func remember(_ run: CommandAgentService.Run, question: String, generation: Int,
                  at now: Date = Date()) {
        guard generation == self.generation else { return }
        guard let result = run.result, !result.createdSomething else {
            held = nil
            return
        }
        held = (Digest(question: question, answer: run.storableAnswer, tainted: run.tainted), now)
    }

    /// The digest while the window is open, handed over once.
    func take(at now: Date = Date()) -> Digest? {
        defer { held = nil }
        guard let held, now.timeIntervalSince(held.at) < Self.duration else { return nil }
        return held.digest
    }

    func clear() {
        held = nil
        generation += 1
    }
}
