import CoreAudio
import Foundation

/// Resolves which input device the capture engine should bind to.
///
/// A Bluetooth headset can't stream hi-fi A2DP playback and microphone input at
/// the same time — opening its mic forces the headset into the low-quality HFP
/// "call" profile, which wrecks playback *and* hands us a worse signal to
/// transcribe (mono, ~8–16 kHz). So when the system default input is a Bluetooth
/// device we capture from the built-in mic instead, leaving the headset in
/// hi-fi. This is a hard Bluetooth limitation, not something an app can tune
/// around; the only fix is to not use the Bluetooth mic.
enum AudioInputResolver {
    /// The device the capture engine should use, or `nil` to keep the system
    /// default. Returns the built-in mic only when `avoidBluetooth` is on, the
    /// current default input is Bluetooth, and a built-in mic exists (so a
    /// deliberately-chosen USB/studio mic is always respected, and Macs without
    /// a built-in mic fall back to the default).
    static func captureDeviceID(avoidBluetooth: Bool) -> AudioDeviceID? {
        guard avoidBluetooth,
              let defaultInput = defaultInputDeviceID(),
              isBluetooth(defaultInput),
              let builtIn = builtInInputDeviceID()
        else { return nil }
        return builtIn
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

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        switch transportType(of: device) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        default:
            return false
        }
    }

    /// First built-in device that actually has input channels — i.e. the
    /// built-in mic, as opposed to the built-in speakers, which share the same
    /// transport type.
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
