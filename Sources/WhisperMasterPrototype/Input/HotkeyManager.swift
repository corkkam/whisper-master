import AppKit

@MainActor
final class HotkeyManager {
    enum Event {
        case pressed
        case released
    }

    enum HotkeyOption: String, CaseIterable, Identifiable {
        case rightOption
        case leftOption
        case rightCommand
        case rightControl

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .rightOption:
                return "Right Option (⌥)"
            case .leftOption:
                return "Left Option (⌥)"
            case .rightCommand:
                return "Right Command (⌘)"
            case .rightControl:
                return "Right Control (⌃)"
            }
        }

        /// Short key-cap style label, e.g. "⌥ R-OPT".
        var compactName: String {
            switch self {
            case .rightOption:
                return "⌥ R-OPT"
            case .leftOption:
                return "⌥ L-OPT"
            case .rightCommand:
                return "⌘ R-CMD"
            case .rightControl:
                return "⌃ R-CTL"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .rightOption:
                return 61
            case .leftOption:
                return 58
            case .rightCommand:
                return 54
            case .rightControl:
                return 62
            }
        }

        var modifierBit: UInt {
            switch self {
            case .rightOption:
                return 0x0040
            case .leftOption:
                return 0x0020
            case .rightCommand:
                return 0x0010
            case .rightControl:
                return 0x2000
            }
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private var hotkey: HotkeyOption
    private let onEvent: (Event) -> Void

    init(hotkey: HotkeyOption, onEvent: @escaping (Event) -> Void) {
        self.hotkey = hotkey
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
        self.hotkey = hotkey
        isDown = false
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
        onEvent(nowDown ? .pressed : .released)
    }
}
