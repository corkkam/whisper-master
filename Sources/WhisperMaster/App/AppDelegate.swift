import AppKit
import Sparkle
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hotkeyManager: HotkeyManager?
    private let permissionsManager = PermissionsManager()
    private let onboardingMic = MicrophoneCaptureService()
    private lazy var viewModel = DictationViewModel(
        hotkeyUpdater: { [weak self] hotkey in
            self?.hotkeyManager?.setHotkey(hotkey)
        }
    )
    private let transcriptionServer = RemoteTranscriptionServer()
    private lazy var meshCoordinator = MeshCoordinator(
        state: viewModel.state,
        server: transcriptionServer
    )
    private var pillWindow: DictationPillWindow?
    private var bluetoothInputMonitor: BluetoothInputMonitor?
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

    /// Sparkle auto-updater. `startingUpdater: true` begins scheduled update
    /// checks (gated by `SUEnableAutomaticChecks` in Info.plist) against the
    /// `SUFeedURL` appcast, verified with the `SUPublicEDKey`.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        setupWindow()
        setupPill()
        setupHotkey()
        startStatusRefreshLoop()

        // Advertise the LAN transcription service so iOS clients can stream
        // audio here and use this Mac's models. Independent of local recording.
        transcriptionServer.start()

        // Discover other Macs running Whisper Master on the network (the mesh).
        meshCoordinator.start()

        // Request notification permission so Sparkle's gentle "update
        // available" reminder can post a banner when the app is in the
        // background. Without authorization Sparkle silently defers it.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Touch the lazy updater so it starts now (startingUpdater: true) and
        // runs scheduled background checks. Without this it would only be
        // created on a manual "Check for Updates…", so automatic update
        // notifications would never fire.
        _ = updaterController

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

    /// Standard Dock-app menu bar. Without it, a `.regular` app has no working
    /// Cmd-Q or Edit shortcuts (cut/copy/paste/select-all/undo) — the latter
    /// matter for the custom-words editor. The tray menu stays the primary surface.
    private func setupMainMenu() {
        let appName = "Whisper Master"
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showWindow), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "WhisperMaster.StatusItem"
        item.behavior = []
        item.isVisible = true

        if let button = item.button {
            button.image = BrandAsset.trayTemplateImage(points: 18) ?? Self.statusImage(symbol: "waveform")
            button.imagePosition = .imageOnly
            button.toolTip = "Whisper Master"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        // Keep the menu a steady width so it doesn't jump around as the status
        // header / history previews change length.
        menu.minimumWidth = 300

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

        // Wired to the Sparkle updater (not self) after the blanket target
        // assignment below.
        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(updates)

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

        // The updater owns its own validation/handling, so point this item at
        // the Sparkle controller instead of the app delegate.
        updates.target = self
        updates.action = #selector(checkForUpdates(_:))

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
        // `nil` symbol → show the brand logo (the calm idle/ready state).
        // Active states keep their SF Symbol so status stays glanceable.
        if let symbol, let image = Self.statusImage(symbol: symbol) {
            button.image = image
        } else if symbol == nil, let logo = BrandAsset.trayTemplateImage(points: 18) {
            button.image = logo
        }
        button.toolTip = tooltip
        statusHeader?.title = headerText

        startItem?.isEnabled = state.canStart
        stopItem?.isEnabled = state.canStop
        cancelItem?.isHidden = state.preparingEngine == nil

        // The notch panel is click-through except while the Bluetooth-mic banner
        // is up, where its button needs to receive clicks.
        pillWindow?.setInteractive(state.shouldShowBluetoothBanner)

        // Drive gentle reminders off the same poll — a cheap, idle-gated check.
        viewModel.evaluateReminders()

        refreshHistoryMenu()
    }

    private func refreshHistoryMenu() {
        guard let historyMenu, let historyMenuItem else { return }
        let entries = viewModel.state.history
        let currentIDs = entries.map(\.id)

        pasteLastItem?.isEnabled = !entries.isEmpty
        if let first = entries.first {
            pasteLastItem?.title = "Paste Last: \(Self.trimMenuTitle(first.preview))"
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
                title: "\(Self.timestampFormatter.string(from: entry.createdAt))  ·  \(Self.trimMenuTitle(entry.preview))",
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

    private static func trimMenuTitle(_ text: String, limit: Int = 26) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<idx]) + "…"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func trayAppearance(for state: AppState) -> (String?, String, String) {
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
            return (nil, "Whisper Master — ready", "Ready")
        }
    }

    private func setupWindow() {
        let rootView = SettingsView(
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
        // Light "Daylight" chrome: paper titlebar that blends with the theme.
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Theme.canvasNSColor
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
        // Watch for a Bluetooth mic input so the notch can offer to switch to
        // the built-in mic (keeps earphones in hi-fi). Read-only detection.
        bluetoothInputMonitor = BluetoothInputMonitor(state: viewModel.state)
        bluetoothInputMonitor?.start()
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
            retryEngine: { [weak self] in self?.viewModel.prepareDefaultEngineOnLaunch() },
            onClose: { [weak self] in
                // User dismissed onboarding early — drop to the tray. They can
                // reopen it any time via the "Reopen Onboarding…" menu item.
                guard let self else { return }
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
            }
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
    private func checkForUpdates(_ sender: Any?) {
        // Bring the app forward so Sparkle's update window/alert appears on top
        // rather than behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(sender)
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
        bluetoothInputMonitor?.stop()
        viewModel.shutdown()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: SPUStandardUserDriverDelegate {
    /// Opt into gentle reminders: Sparkle defers its window for scheduled
    /// updates and leaves it to us to remind the user — which we do with a
    /// notification (below), so they see an update without opening the app.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if state.userInitiated {
            // Manual check: bring the update window to the front.
            NSApp.activate(ignoringOtherApps: true)
        } else if !NSApp.isActive {
            // Scheduled check while backgrounded: post the gentle reminder
            // ourselves (Sparkle won't). Tapping it activates the app, which
            // surfaces Sparkle's deferred update prompt to install.
            postUpdateAvailableNotification(for: update)
        }
    }

    private func postUpdateAvailableNotification(for update: SUAppcastItem) {
        let content = UNMutableNotificationContent()
        content.title = "Update available"
        content.body = "Whisper Master \(update.displayVersionString) is ready to install."
        let request = UNNotificationRequest(
            identifier: "app.whispermaster.update-available",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
