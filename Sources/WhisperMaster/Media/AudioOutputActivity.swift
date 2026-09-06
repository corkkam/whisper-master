import CoreAudio
import Foundation

/// Who is playing sound out of the speakers right now.
///
/// **This reads Core Audio; it never writes it.** The prohibition in
/// `Audio/CLAUDE.md` is about *setting* HAL properties to re-route devices, which
/// hung `coreaudiod` three separate ways. Enumerating the process objects sets
/// nothing and touches no device — but each read is still an IPC round trip, so
/// every caller here runs it off the main actor rather than on the key-press path.
enum AudioOutputActivity {
    /// Bundle identifiers of every process currently sending audio to the output
    /// device, newest Core Audio object last. A process with no bundle (a
    /// command-line tool such as `afplay`) reports an empty string.
    ///
    /// Returns an empty list on macOS 14.0 / 14.1, where the process object list
    /// does not exist — the feature then simply never fires, which is the same
    /// outcome as nothing playing.
    static func runningOutputBundleIDs() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        return processObjects().compactMap { object in
            guard isRunningOutput(object) else { return nil }
            return bundleID(of: object) ?? ""
        }
    }

    // MARK: - Core Audio

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var objects = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    @available(macOS 14.2, *)
    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    @available(macOS 14.2, *)
    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Initialised to nil on purpose: Core Audio writes a +1 reference into this
        // slot, and ARC balances it when the variable goes out of scope. Seeding it
        // with a real string instead would overwrite that reference and leak it once
        // per process, twice per dictation.
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
