import Foundation

/// Single entry point for session tracing. The `DIAGNOSTICS` compile flag — set
/// only for the local developer build (`DIAGNOSTICS=1 bash Scripts/install.sh`),
/// never by CI Release — is the only thing that swaps in the real recorder. Every
/// other build gets `NoopDiagnostics`, so no session JSON or audio can ever be
/// written on a machine other than the developer's.
enum Diagnostics {
    #if DIAGNOSTICS
    @MainActor static let shared: DiagnosticsRecording = DiagnosticsRecorder()
    /// Whether this build records — handy for a status line / log at launch.
    static let isEnabled = true
    #else
    @MainActor static let shared: DiagnosticsRecording = NoopDiagnostics()
    static let isEnabled = false
    #endif
}
