import AppKit

@MainActor
final class HotkeyManager {
    enum Event {
        /// Begin a recording (the key went down, or a tap toggled it on).
        case start
        /// End the current recording.
        case stop
        /// Keep the running recording open without the key — a double-tap latched
        /// it hands-free.
        case handsFree
        /// Toggle mode (`holdToTalkEnabled` off): one tap flips the state.
        case toggle
    }

    enum HotkeyOption: String, CaseIterable, Identifiable {
        case fn
        case rightOption
        case leftOption
        case rightCommand

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fn:
                return "Globe / fn (🌐)"
            case .rightOption:
                return "Right Option (⌥)"
            case .leftOption:
                return "Left Option (⌥)"
            case .rightCommand:
                return "Right Command (⌘)"
            }
        }

        /// Short key-cap style label, e.g. "⌥ R-OPT".
        var compactName: String {
            switch self {
            case .fn:
                return "🌐 FN"
            case .rightOption:
                return "⌥ R-OPT"
            case .leftOption:
                return "⌥ L-OPT"
            case .rightCommand:
                return "⌘ R-CMD"
            }
        }

        /// The bare key, for a one-line hint on a narrow surface ("Hold 🌐 to
        /// dictate"). `sentenceName`'s "the 🌐 key" wording is too long there and
        /// `compactName`'s "🌐 FN" reads as two keys.
        var capName: String {
            switch self {
            case .fn:
                return "🌐"
            case .rightOption:
                return "right ⌥"
            case .leftOption:
                return "left ⌥"
            case .rightCommand:
                return "right ⌘"
            }
        }

        /// Reads inside a sentence ("Hold the 🌐 key and talk"), where the menu's
        /// `displayName` would land as a parenthetical.
        var sentenceName: String {
            switch self {
            case .fn:
                return "the 🌐 key"
            case .rightOption:
                return "right ⌥"
            case .leftOption:
                return "left ⌥"
            case .rightCommand:
                return "right ⌘"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .fn:
                return 63
            case .rightOption:
                return 61
            case .leftOption:
                return 58
            case .rightCommand:
                return 54
            }
        }

        /// The device-dependent modifier bit that is set while this key is held.
        /// `fn` uses `NX_SECONDARYFNMASK`, which `NSEvent.ModifierFlags.function`
        /// also carries for arrow / F-keys — harmless, since `handle` matches on
        /// the key code first and those arrive as key-downs, not flag changes.
        var modifierBit: UInt {
            switch self {
            case .fn:
                return 0x0080_0000
            case .rightOption:
                return 0x0040
            case .leftOption:
                return 0x0020
            case .rightCommand:
                return 0x0010
            }
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private var hotkey: HotkeyOption
    private let onEvent: (Event) -> Void
    /// Reads the live hold-to-talk preference. Toggle mode bypasses the gesture
    /// recogniser entirely: there is nothing to latch when every tap already flips
    /// the state.
    private let holdToTalk: () -> Bool
    /// Whether a double-tap on this key latches dictation hands-free. Off for the
    /// dedicated day-query key, which stays plain push-to-talk.
    private let latchesOnDoubleTap: Bool
    private var gesture = HotkeyGesture()
    private var flushTimer: Timer?

    init(
        hotkey: HotkeyOption,
        latchesOnDoubleTap: Bool = true,
        holdToTalk: @escaping () -> Bool = { true },
        onEvent: @escaping (Event) -> Void
    ) {
        self.hotkey = hotkey
        self.latchesOnDoubleTap = latchesOnDoubleTap
        self.holdToTalk = holdToTalk
        self.onEvent = onEvent
        install()
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    func setHotkey(_ hotkey: HotkeyOption) {
        guard hotkey != self.hotkey else { return }
        self.hotkey = hotkey
        isDown = false
        resetGesture()
    }

    /// Forget any half-finished gesture — called when the session ends by some
    /// route other than this key (tray stop, failure, sign-out), so a stale
    /// hands-free latch can't carry into the next recording.
    func resetGesture() {
        flushTimer?.invalidate()
        flushTimer = nil
        gesture.reset()
    }

    private func install() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let nowDown = (event.modifierFlags.rawValue & hotkey.modifierBit) != 0
        guard nowDown != isDown else { return }
        isDown = nowDown

        // Toggle mode: one press flips the state, the release means nothing.
        guard holdToTalk() else {
            resetGesture()
            if nowDown { onEvent(.toggle) }
            return
        }

        // `NSEvent.timestamp` is seconds since boot — the same monotonic base as
        // `ProcessInfo.systemUptime`, which drives the deferred-stop timer.
        let now = event.timestamp
        guard latchesOnDoubleTap else {
            onEvent(nowDown ? .start : .stop)
            return
        }

        let signal = nowDown ? gesture.press(now: now) : gesture.release(now: now)
        emit(signal)
        scheduleFlushIfNeeded()
    }

    private func emit(_ signal: HotkeyGesture.Signal?) {
        switch signal {
        case .start: onEvent(.start)
        case .stop: onEvent(.stop)
        case .handsFreeOn: onEvent(.handsFree)
        case nil: break
        }
    }

    /// Arm (or disarm) the timer that resolves a lone tap into the stop the
    /// recogniser deferred while waiting for a possible second tap.
    private func scheduleFlushIfNeeded() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard let deadline = gesture.pendingStopAt else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        flushTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushGesture() }
        }
    }

    private func flushGesture() {
        flushTimer = nil
        emit(gesture.flush(now: ProcessInfo.processInfo.systemUptime))
        scheduleFlushIfNeeded()
    }
}
