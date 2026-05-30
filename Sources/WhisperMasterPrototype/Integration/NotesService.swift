import Foundation

actor NotesService {
    func createNote(body: String) async throws {
        let escaped = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let script = """
        tell application "Notes"
            activate
            make new note at folder "Notes" of default account with properties {body:"\(escaped)"}
        end tell
        """

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(throwing: NotesServiceError.scriptFailed("Could not create AppleScript"))
                    return
                }
                appleScript.executeAndReturnError(&error)
                if let error {
                    let msg = (error[NSAppleScript.errorMessage as NSString] as? String) ?? "Unknown AppleScript error"
                    continuation.resume(throwing: NotesServiceError.scriptFailed(msg))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    enum NotesServiceError: LocalizedError {
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let msg): return "Apple Notes error: \(msg)"
            }
        }
    }
}
