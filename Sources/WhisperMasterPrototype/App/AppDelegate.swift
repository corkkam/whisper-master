import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hotkeyManager: HotkeyManager?
    private let permissionsManager = PermissionsManager()
    private let onboardingMic = MicrophoneCaptureService()
    private lazy var viewModel = PrototypeViewModel(
        hotkeyUpdater: { [weak self] hotkey in
            self?.hotkeyManager?.setHotkey(hotkey)
        }
    )
    private var pillWindow: DictationPillWindow?
    private var onboardingWindow: OnboardingWindow?
    private var statusRefreshTimer: Timer?
    private var settingsItem: NSMenuItem?
    private var statusHeader: NSMenuItem?
    private var startItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var pasteLastItem: NSMenuItem?
    private var historyMenu: NSMenu?
    private var historyMenuItem: NSMenuItem?
    private var historySeparator: NSMenuItem?
    private var renderedHistoryIDs: [UUID] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupWindow()
        setupPill()
        setupHotkey()
        startStatusRefreshLoop()

        // Start downloading/loading the voice engine immediately, in parallel
        // with onboarding. Model preparation only needs the network, not the
        // mic/accessibility permissions the wizard collects — so by the time
        // the user reaches the last step it's ideally already ready.
        viewModel.prepareDefaultEngineOnLaunch()

        if needsOnboarding {
            showOnboarding()
        } else if !viewModel.state.selectedEngine.isInstalled {
            showWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc
    private func statusButtonClicked(_ sender: NSStatusBarButton) {
        // Menu is attached via item.menu — let AppKit handle it. This stub
        // exists so the button has a target and accepts both mouse buttons.
    }

    private var needsOnboarding: Bool {
        permissionsManager.microphoneStatus() != .granted
            || !permissionsManager.accessibilityGranted()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "WhisperMaster.StatusItem"
        item.behavior = []
        item.isVisible = true

        if let button = item.button {
            button.image = Self.statusImage(symbol: "waveform")
            button.imagePosition = .imageOnly
            button.toolTip = "Whisper Master"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: "Whisper Master", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        statusHeader = header

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showWindow),
            keyEquivalent: ","
        )
        menu.addItem(settings)
        settingsItem = settings

        menu.addItem(
            NSMenuItem(
                title: "Reopen Onboarding…",
                action: #selector(showOnboardingFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(.separator())

        let pasteLast = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLast),
            keyEquivalent: "v"
        )
        pasteLast.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pasteLast)
        pasteLastItem = pasteLast

        let historyItem = NSMenuItem(
            title: "Recent Transcripts",
            action: nil,
            keyEquivalent: ""
        )
        let historySub = NSMenu()
        historyItem.submenu = historySub
        menu.addItem(historyItem)
        historyMenu = historySub
        historyMenuItem = historyItem

        let separator = NSMenuItem.separator()
        menu.addItem(separator)
        historySeparator = separator

        let start = NSMenuItem(
            title: "Start Recording",
            action: #selector(startRecording),
            keyEquivalent: ""
        )
        menu.addItem(start)
        startItem = start

        let stop = NSMenuItem(
            title: "Stop Recording",
            action: #selector(stopRecording),
            keyEquivalent: ""
        )
        menu.addItem(stop)
        stopItem = stop

        let cancel = NSMenuItem(
            title: "Cancel Voice Engine Setup",
            action: #selector(cancelVoiceEngineSetup),
            keyEquivalent: ""
        )
        menu.addItem(cancel)
        cancelItem = cancel

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Whisper Master",
                action: #selector(quitApp),
                keyEquivalent: "q"
            )
        )

        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private static func statusImage(symbol: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Whisper Master"
        )?.withSymbolConfiguration(config) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private func startStatusRefreshLoop() {
        statusRefreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusItem()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusRefreshTimer = timer
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        let state = viewModel.state

        let (symbol, tooltip, headerText) = trayAppearance(for: state)
        if let image = Self.statusImage(symbol: symbol) {
            button.image = image
        }
        button.toolTip = tooltip
        statusHeader?.title = headerText

        startItem?.isEnabled = state.canStart
        stopItem?.isEnabled = state.canStop
        cancelItem?.isHidden = state.preparingEngine == nil

        refreshHistoryMenu()
    }

    private func refreshHistoryMenu() {
        guard let historyMenu, let historyMenuItem else { return }
        let entries = viewModel.state.history
        let currentIDs = entries.map(\.id)

        pasteLastItem?.isEnabled = !entries.isEmpty
        if let first = entries.first {
            pasteLastItem?.title = "Paste Last: \(first.preview)"
        } else {
            pasteLastItem?.title = "Paste Last Transcript"
        }

        historyMenuItem.isEnabled = !entries.isEmpty
        guard currentIDs != renderedHistoryIDs else { return }
        renderedHistoryIDs = currentIDs

        historyMenu.removeAllItems()

        if entries.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
            return
        }

        let display = Array(entries.prefix(10))
        for (index, entry) in display.enumerated() {
            let item = NSMenuItem(
                title: "\(Self.timestampFormatter.string(from: entry.createdAt))  ·  \(entry.preview)",
                action: #selector(pasteHistoryItem(_:)),
                keyEquivalent: index < 9 ? String(index + 1) : ""
            )
            if index < 9 {
                item.keyEquivalentModifierMask = [.command, .shift]
            }
            item.target = self
            item.representedObject = entry.id.uuidString
            item.toolTip = entry.text
            historyMenu.addItem(item)
        }

        historyMenu.addItem(.separator())

        let copyLast = NSMenuItem(
            title: "Copy Last to Clipboard",
            action: #selector(copyLastToClipboard),
            keyEquivalent: "c"
        )
        copyLast.keyEquivalentModifierMask = [.command, .shift]
        copyLast.target = self
        historyMenu.addItem(copyLast)

        let clear = NSMenuItem(
            title: "Clear History",
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clear.target = self
        historyMenu.addItem(clear)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func trayAppearance(for state: PrototypeAppState) -> (String, String, String) {
        if state.preparingEngine != nil {
            let percent = Int((state.download?.fractionCompleted ?? 0) * 100)
            let label = "Setting up voice engine — \(percent)%"
            return ("arrow.down.circle", label, label)
        }
        switch state.phase {
        case .recording:
            return ("waveform.circle.fill", "Whisper Master — recording", "Recording…")
        case .stopping:
            return ("waveform.circle", "Whisper Master — finalizing", "Finalizing…")
        case .preparingModels:
            return ("arrow.down.circle", "Whisper Master — preparing", "Preparing…")
        case .failed:
            return ("exclamationmark.triangle.fill", "Whisper Master — error", "Error")
        case .idle:
            if !state.selectedEngine.isInstalled {
                return ("arrow.down.circle", "Whisper Master — voice engine not installed", "Voice engine not installed")
            }
            return ("waveform", "Whisper Master — ready", "Ready")
        }
    }

    private func setupWindow() {
        let rootView = PrototypeView(
            viewModel: viewModel,
            state: viewModel.state,
            reopenOnboarding: { [weak self] in self?.showOnboarding() },
            startSetup: { [weak self] in self?.viewModel.prepareSelectedEngineInBackground() },
            cancelSetup: { [weak self] in self?.viewModel.cancelModelPreparation() }
        )
        let host = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Master"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.setFrameAutosaveName("WhisperMaster.SettingsWindow")
        self.window = window
    }

    private func setupPill() {
        pillWindow = DictationPillWindow(state: viewModel.state)
        pillWindow?.show()
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager(hotkey: viewModel.state.hotkey) { [weak self] event in
            guard let self else { return }
            switch event {
            case .pressed:
                self.viewModel.handleHotkeyPressed()
            case .released:
                self.viewModel.handleHotkeyReleased()
            }
        }
    }

    private func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.show()
            return
        }

        onboardingWindow = OnboardingWindow(
            state: viewModel.state,
            permissions: permissionsManager,
            microphoneCapture: onboardingMic,
            retryEngine: { [weak self] in self?.viewModel.prepareDefaultEngineOnLaunch() }
        ) { [weak self] in
            guard let self else { return }
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            // Engine prep was kicked off at launch; retry here only if it
            // never started or previously failed (the call is idempotent).
            self.viewModel.prepareDefaultEngineOnLaunch()
            self.showWindow()
        }
        onboardingWindow?.show()
    }

    @objc
    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    @objc
    private func showOnboardingFromMenu() {
        showOnboarding()
    }

    @objc
    private func startRecording() {
        viewModel.startRecording()
    }

    @objc
    private func stopRecording() {
        viewModel.stopRecording()
    }

    @objc
    private func cancelVoiceEngineSetup() {
        viewModel.cancelModelPreparation()
    }

    @objc
    private func pasteLast() {
        viewModel.pasteLastTranscript()
    }

    @objc
    private func pasteHistoryItem(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let entry = viewModel.state.history.first(where: { $0.id == id }) else { return }
        viewModel.pasteText(entry.text)
    }

    @objc
    private func copyLastToClipboard() {
        guard let first = viewModel.state.history.first else { return }
        viewModel.copyToClipboard(first.text)
    }

    @objc
    private func clearHistory() {
        viewModel.clearAllHistory()
        refreshHistoryMenu()
    }

    @objc
    private func quitApp() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
        viewModel.shutdown()
        NSApp.terminate(nil)
    }
}
