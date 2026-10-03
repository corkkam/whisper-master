import Foundation

/// Which model the shipped paths load, when a dev build has been told to use a
/// different one.
///
/// **This is the one place the lab reaches into the product**, and it is fenced
/// three ways. It is refused outright on any channel but `dev`, so a stable or
/// beta binary cannot be talked into loading a model it never shipped, whatever
/// is in its defaults. It is validated against the filesystem on every read, so a
/// model the user deleted falls back to the shipped one rather than wedging
/// cleanup on a missing directory. And it stores a **catalogue id**, not a path,
/// so nothing can be pointed at an arbitrary folder. A model added by its Hugging
/// Face id is a catalogue id too: its directory is derived from a repo id that
/// `LabCustomModels` re-checks on every read, never from a stored path.
///
/// Read from `CleanupModel.directory` and `CleanupModel.General.directory`, which
/// is deliberately low: everything downstream — the installer's `isInstalled`
/// check, the manager's retry loop, the Settings hint — then sees one consistent
/// answer to "which model is this".
enum LabModelOverride {
    static let cleanupKey = "WhisperMaster.lab.cleanupModel.v1"
    static let assistantKey = "WhisperMaster.lab.assistantModel.v1"

    /// Only a dev build may honour an override. The lab page is gated the same
    /// way, but the gate is repeated here because this is the side that matters:
    /// the UI being unreachable is a convenience, the model not loading is the
    /// guarantee.
    static var isPermitted: Bool { ReleaseChannel.current == .dev }

    static func key(for role: LabRole) -> String {
        role == .cleanup ? cleanupKey : assistantKey
    }

    /// The catalogue id currently chosen for a slot, ignoring whether it is still
    /// on disk. The lab shows this so a broken override is visible rather than
    /// silently inert.
    static func modelID(for role: LabRole, defaults: UserDefaults = .standard) -> String? {
        guard isPermitted else { return nil }
        return defaults.string(forKey: key(for: role))
    }

    static func model(for role: LabRole, defaults: UserDefaults = .standard) -> LabModel? {
        modelID(for: role, defaults: defaults).flatMap { LabCatalog.model(id: $0, defaults: defaults) }
    }

    /// The directory to load, or nil to use the shipped model. Nil whenever the
    /// override names a model that is not installed right now.
    ///
    /// Nil for a reasoning row too. The shipped paths cannot reason (they render
    /// with `enable_thinking: false` on a 12-second budget), and a model that
    /// always does would time out on every turn of a dev build's assistant.
    static func directory(for role: LabRole, defaults: UserDefaults = .standard) -> URL? {
        guard let model = model(for: role, defaults: defaults), !model.thinks else { return nil }
        return LabPaths.installedDirectory(for: model)
    }

    static func set(_ modelID: String?, for role: LabRole, defaults: UserDefaults = .standard) {
        guard isPermitted else { return }
        if let modelID {
            defaults.set(modelID, forKey: key(for: role))
        } else {
            defaults.removeObject(forKey: key(for: role))
        }
    }

    /// True when this slot is running something other than what ships. Drives the
    /// warning the lab and the engine page both show, because a dev build quietly
    /// running a different cleanup model would make every other bug report on it
    /// unreadable.
    static func isOverridden(_ role: LabRole, defaults: UserDefaults = .standard) -> Bool {
        directory(for: role, defaults: defaults) != nil
    }
}
