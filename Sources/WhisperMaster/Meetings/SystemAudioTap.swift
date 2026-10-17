@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Captures what a meeting app plays — the other people on the call — through a
/// Core Audio **process tap** (macOS 14.2+).
///
/// **Why a tap and not ScreenCaptureKit:** a tap asks for "audio recording"
/// consent only (`NSAudioCaptureUsageDescription`), not Screen Recording, and it
/// can take just the call app's audio instead of every notification sound.
///
/// **Why this is not the device juggling `Audio/CLAUDE.md` forbids:** nothing here
/// sets a HAL property on an existing device or changes a default. Apple's only
/// way to read a tap is a **private** aggregate device that holds it; it is
/// invisible to other apps and to Sound settings, and it is destroyed in `stop()`.
/// The user's input and output stay exactly where they were.
///
/// **Set up and torn down off the main actor.** Every call here is an IPC round
/// trip to `coreaudiod`, which has stalled the app before (`Audio/CLAUDE.md`), so
/// `start` and `stop` run on `controlQueue` and the caller only awaits them. The
/// IDs below are touched only there (and by `deinit`, when nothing else can).
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case tapCreateFailed(OSStatus)
        case formatUnavailable
        case aggregateCreateFailed(OSStatus)
        case ioProcFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreateFailed: return "Could not capture call audio. Allow audio recording in System Settings."
            case .formatUnavailable: return "Could not read the call audio format."
            case .aggregateCreateFailed, .ioProcFailed: return "Could not start capturing call audio."
            }
        }
    }

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// Where the IO block runs.
    private let ioQueue = DispatchQueue(label: "WhisperMaster.SystemAudioTap", qos: .userInitiated)
    /// Where setup and teardown run. Not `ioQueue`: destroying an IO proc waits for
    /// its block to return, and that wait must not hold the queue the block needs.
    private let controlQueue = DispatchQueue(label: "WhisperMaster.SystemAudioTap.control", qos: .userInitiated)

    /// Start capturing. `bundleFamily` selects the processes to tap; when none of
    /// them is a Core Audio client yet (a web call whose tab has not played sound),
    /// it falls back to everything this Mac plays except ourselves. An empty
    /// family (a meeting started by hand) takes that fallback directly.
    func start(bundleFamily: String, handler: @escaping BufferHandler) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                do {
                    try self.create(bundleFamily: bundleFamily, handler: handler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                self.destroy()
                continuation.resume()
            }
        }
    }

    deinit { destroy() }

    // MARK: - Core Audio

    private func create(bundleFamily: String, handler: @escaping BufferHandler) throws {
        let processes = bundleFamily.isEmpty
            ? [] : AudioOutputActivity.processObjects(bundlePrefix: bundleFamily)
        let description: CATapDescription
        if processes.isEmpty {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObject().map { [$0] } ?? [])
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Whisper Master meeting notes"

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw TapError.tapCreateFailed(tapStatus) }
        tapID = tap

        do {
            guard var asbd = tapFormat(tap),
                  let format = AVAudioFormat(streamDescription: &asbd)
            else { throw TapError.formatUnavailable }
            try createAggregate(tapUUID: description.uuid)
            try startIO(format: format, handler: handler)
        } catch {
            destroy()
            throw error
        }
    }

    private func destroy() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func createAggregate(tapUUID: UUID) throws {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Whisper Master meeting tap",
            kAudioAggregateDeviceUIDKey: "app.whispermaster.meeting-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        // The output device gives the aggregate its clock. Read-only lookup.
        if let outputUID = Self.defaultOutputUID() {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw TapError.aggregateCreateFailed(status) }
        aggregateID = aggregate
    }

    private func startIO(format: AVAudioFormat, handler: @escaping BufferHandler) throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            guard let wrapped = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                wrapped.frameLength > 0,
                let copy = Self.copy(wrapped)
            else { return }
            handler(copy)
        }
        guard status == noErr, let procID else { throw TapError.ioProcFailed(status) }
        ioProcID = procID
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else { throw TapError.ioProcFailed(startStatus) }
    }

    /// The IO block's buffer belongs to Core Audio and is reused on the next
    /// cycle, so it is copied before it leaves the callback.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let from = src.mData, let to = dst.mData else { continue }
            memcpy(to, from, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }

    private func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    private func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        // Nil-seeded for the same +1 reference reason as `AudioOutputActivity.bundleID`.
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { return nil }
        return uid as String
    }
}
