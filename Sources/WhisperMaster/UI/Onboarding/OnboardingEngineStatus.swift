import Foundation

/// Where the voice engine is, as the Ready beat tells it. Read from `AppState`;
/// the onboarding model never touches that state, so the window hands it this.
enum EngineStatus: Equatable {
    /// Prepared, and the prepared engine is the selected one.
    case ready
    /// A download is running.
    case downloading(percent: Int)
    /// Anything else short of ready, including a prep that has not started yet.
    case preparing
    /// The last prep failed and nothing is running now.
    case failed

    static func resolve(
        prepared: TranscriberEngine?,
        selected: TranscriberEngine,
        preparing: TranscriberEngine?,
        phaseFailed: Bool,
        download: ModelDownloadSnapshot?
    ) -> EngineStatus {
        if prepared == selected { return .ready }
        if let download {
            let percent = Int(download.fractionCompleted * 100)
            return .downloading(percent: min(100, max(0, percent)))
        }
        if phaseFailed, preparing == nil { return .failed }
        return .preparing
    }

    @MainActor
    init(_ state: AppState) {
        let phaseFailed: Bool
        if case .failed = state.phase { phaseFailed = true } else { phaseFailed = false }
        self = Self.resolve(
            prepared: state.preparedEngine,
            selected: state.selectedEngine,
            preparing: state.preparingEngine,
            phaseFailed: phaseFailed,
            download: state.download
        )
    }
}

/// The microphone as the Ready beat sees it. Not `MicStatus`:
/// `PermissionsManager.MicStatus` already has that name.
enum ReadyMicStatus: Equatable {
    /// Never asked (`notDetermined`).
    case notAsked
    /// Refused or restricted.
    case denied
    case on

    init(_ status: PermissionsManager.MicStatus) {
        switch status {
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        case .granted: self = .on
        }
    }
}
