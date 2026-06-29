import CoreAudio
import Foundation

/// Keeps Bluetooth headsets out of the microphone role so they stay in hi-fi.
///
/// A Bluetooth headset can't do hi-fi A2DP playback and mic input at once —
/// using its mic forces it into the low-quality HFP "call" profile (mono,
/// ~8 kHz), degrading playback *and* the signal we transcribe. This is a hard
/// Bluetooth limitation, not something an app can tune around. The established
/// fix (Apple's own guidance, and tools like the Hammerspoon audio fix) is to
/// move the *system default input* to the built-in mic and **leave it there** —
/// not swap it per use, which just thrashes the audio route.
enum AudioInputResolver {
    /// If the current default input is a Bluetooth device, switch the system
    /// default input to the built-in mic and leave it. Persistent by design:
    /// once the input is the built-in mic, later recordings don't re-route, so
    /// there's no race or thrash. The user can re-select their Bluetooth mic
    /// manually (or via the settings toggle) if they actually want it.
    /// - Returns: `true` if it switched the input device.
    @discardableResult
    static func switchInputAwayFromBluetooth() -> Bool {
        guard let current = defaultInputDeviceID(),
              isBluetooth(current),
              let builtIn = builtInInputDeviceID(),
              builtIn != current
        else { return false }
        return setDefaultInputDevice(builtIn)
    }

    // MARK: - HAL queries

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    @discardableResult
    private static func setDefaultInputDevice(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = device
        let status = AudioObjectSetPropertyData(
            systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        return status == noErr
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        switch transportType(of: device) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        default:
            return false
        }
    }

    /// First built-in device that actually has input channels — i.e. the
    /// built-in mic, not the built-in speakers (which share the transport type).
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
