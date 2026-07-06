import Foundation

/// The default formatter: rewrites the transcript with `DeterministicITN` rules.
/// Always available, instant, on-device, and fully deterministic — the same
/// input always produces the same output, with no model and no resource use.
struct DeterministicTextFormatter: TextFormatting {
    var isAvailable: Bool { true }
    var isInstant: Bool { true }
    func prewarm() async {}
    func format(_ text: String) async -> String { DeterministicITN.normalize(text) }
}
