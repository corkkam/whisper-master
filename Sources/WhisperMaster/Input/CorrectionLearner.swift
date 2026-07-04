import ApplicationServices
import Foundation

/// Watches the field we just pasted into and learns from the user's fix-ups.
///
/// After an injection, polls the focused element's text for a while; when the
/// user replaces exactly one pasted word (per `CorrectionDetector`), reports
/// the correction so it can be added to the custom vocabulary. Reads only the
/// field the app itself pasted into, and only briefly — never a keylogger.
@MainActor
final class CorrectionLearner {
    /// How often the field is re-read while watching.
    private static let pollInterval: UInt64 = 3_000_000_000
    /// Polls before giving up (~45 s — corrections happen right after pasting).
    private static let maxPolls = 15

    private var watchTask: Task<Void, Never>?

    func watch(injected: String, onLearn: @escaping @MainActor (CorrectionDetector.Correction) -> Void) {
        cancel()
        guard let element = FocusedElementInspector.focusedElement() else { return }

        watchTask = Task { [weak self] in
            defer { self?.watchTask = nil }
            var consecutiveMisses = 0
            for _ in 0..<Self.maxPolls {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                if Task.isCancelled { return }

                guard let current = FocusedElementInspector.stringValue(of: element) else {
                    // Field gone (window closed, focus moved on) — stop quietly.
                    consecutiveMisses += 1
                    if consecutiveMisses >= 2 { return }
                    continue
                }
                consecutiveMisses = 0

                if let correction = CorrectionDetector.detectSingleWordReplacement(
                    injected: injected, current: current
                ) {
                    onLearn(correction)
                    return
                }
            }
        }
    }

    func cancel() {
        watchTask?.cancel()
        watchTask = nil
    }
}
