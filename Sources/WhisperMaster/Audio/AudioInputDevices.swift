import CoreAudio
import Foundation

/// Read-only inspection of the system audio input, plus a single user-initiated
/// switch to the built-in mic.
///
/// A Bluetooth headset can't do hi-fi A2DP playback and mic input at once —
/// using its mic forces the low-quality HFP "call" profile. We never switch
/// devices automatically inside the recording path (that hung Core Audio); the
/// only mutation here is `switchToBuiltInMic()`, called once when the *user*
/// taps the notch banner, while idle and off the main thread.
enum AudioInputDevices {
    /// Whether the current default input is a Bluetooth device (classic or LE).
    /// Read-only and cheap — safe to poll.
    static func isDefaultInputBluetooth() -> Bool {
        guard let device = defaultInputDeviceID() else { return false }
        switch transportType(of: device) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        default:
            return false
        }
    }

    /// Move the system default input to the built-in mic. The same operation the
    /// Sound settings pane performs — one synchronous Core Audio set, nothing
    /// else. Call off the main thread. Returns `true` if it switched.
    @discardableResult
    static func switchToBuiltInMic() -> Bool {
        guard let builtIn = builtInInputDeviceID(),
              builtIn != defaultInputDeviceID()
        else { return false }
        var id = builtIn
        var address = defaultInputAddress
        let status = AudioObjectSetPropertyData(
            systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        return status == noErr
    }

    // MARK: - HAL queries

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = defaultInputAddress
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// First built-in device that actually has input channels — the built-in
    /// mic, not the built-in speakers (which share the transport type).
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        allDeviceIDs().first { device in
            transportType(of: device) == kAudioDeviceTransportTypeBuiltIn
                && inputChannelCount(of: device) > 0
        }
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr
        else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &devices) == noErr
        else { return [] }
        return devices
    }

    /// Human-readable name of the current default input device — read-only, for
    /// diagnostics (e.g. "MacBook Pro Microphone", "AirPods Pro"). Never mutates
    /// device state, so it's safe outside the recording path.
    static func currentInputName() -> String {
        guard let device = defaultInputDeviceID() else { return "unknown" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        return status == noErr ? (name as String) : "unknown"
    }

    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr
        else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
