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

    /// Bundle identifiers of every **other** process reading from an input
    /// device right now. The meeting detector's evidence: a call app holds the mic
    /// for as long as the call runs. Our own process is left out, so our own
    /// dictation and meeting recording never look like someone else's call.
    static func runningInputBundleIDs() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        let me = getpid()
        return processObjects().compactMap { object in
            guard pid(of: object) != me, isRunning(object, kAudioProcessPropertyIsRunningInput)
            else { return nil }
            return bundleID(of: object) ?? ""
        }
    }

    /// The Core Audio process objects whose bundle id starts with `prefix`, for a
    /// process tap on one app's audio. Prefix, because Chrome and Zoom play from
    /// helper processes with their own suffixed ids.
    @available(macOS 14.2, *)
    static func processObjects(bundlePrefix prefix: String) -> [AudioObjectID] {
        let me = getpid()
        return processObjects().filter { object in
            guard pid(of: object) != me, let id = bundleID(of: object) else { return false }
            return id.hasPrefix(prefix)
        }
    }

    // MARK: - Core Audio

    @available(macOS 14.2, *)
    static func processObjects() -> [AudioObjectID] {
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
        isRunning(object, kAudioProcessPropertyIsRunningOutput)
    }

    @available(macOS 14.2, *)
    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    @available(macOS 14.2, *)
    private static func isRunning(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
