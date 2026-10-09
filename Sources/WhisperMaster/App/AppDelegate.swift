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
    // Net-new local stores backing the Organic screens (Today / Notes / Connectors
    // / Account). All on-device; no backend.
    private let notesStore = NotesStore()
    private let connectorStore = ConnectorStore()
    private let accountStore = AccountStore()
    private lazy var meshCoordinator = MeshCoordinator(
        state: viewModel.state,
        server: transcriptionServer
    )
    private var pillWindow: DictationPillWindow?
    private var bluetoothInputMonitor: BluetoothInputMonitor?
    private var onboardingWindow: OnboardingWindow?
    private var authGateWindow: AuthGateWindow?
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
        // Register the bundled Organic display/body faces (Caprasimo + Figtree)
        // before any SwiftUI surface builds its type. Idempotent; falls back to
        // system fonts if a face is missing.
        BrandFonts.registerAll()
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

        // Sparkle's gentle "update available" reminder posts a macOS
        // notification. The delegate is required so the banner shows even while
        // the app is active (willPresent) and tapping it triggers the update
        // (didReceive) — without it the notification is suppressed/inert. The
        // authorization *request* is deferred below: when onboarding runs, its
        // Notifications step owns the prompt so it doesn't surprise the user
        // before the window even appears.
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self

        // Touch the lazy updater so it starts now (startingUpdater: true) and
        // runs scheduled background checks. Without this it would only be
        // created on a manual "Check for Updates…", so automatic update
        // notifications would never fire.
        _ = updaterController

        // Create the background download session now, before any model prep
        // asks for a download. On relaunch this lets `nsurlsessiond` replay
        // completion events for transfers it finished while we were quit — moving
        // finished archives into place — so a subsequent download() sees the file
        // already present instead of racing and re-downloading it.
        _ = BackgroundFileDownloader.shared

        // Start downloading/loading the voice engine immediately, in parallel
        // with onboarding. Model preparation only needs the network, not the
        // mic/accessibility permissions the wizard collects — so by the time
        // the user reaches the last step it's ideally already ready.
        viewModel.prepareDefaultEngineOnLaunch()

        // Dev-only: when WM_EVAL_CASES is set, grade the real pipeline over those
        // cases and write results.json, then leave the app running for inspection.
        if ProcessInfo.processInfo.environment["WM_EVAL_CASES"] != nil {
            Task { await EvalRunner.runIfRequested() }
        }

        // Anonymous, opt-in usage analytics (off unless the user enabled it in
        // Settings). Configure from the persisted flag, then record this launch.
        Analytics.shared.configure(enabled: viewModel.state.analyticsEnabled)
        reportLaunchAnalytics()

        // A local, non-blocking welcome/auth gate on first run: put a name in for
        // the greeting or continue as a guest. Once past it (either way) the
        // normal onboarding/window flow runs.
        if !accountStore.isSignedIn {
            showAuthGate { [weak self] in
                self?.continueLaunch(notificationCenter: notificationCenter)
            }
        } else {
            continueLaunch(notificationCenter: notificationCenter)
        }
    }

    /// The launch flow after the auth gate: onboarding for new users, or a jump
    /// to Settings when the voice engine still needs installing.
    private func continueLaunch(notificationCenter: UNUserNotificationCenter) {
        if needsOnboarding {
            showOnboarding()
        } else {
            // Past onboarding (it won't show), so ask for notification permission
            // here instead — the onboarding step that normally owns the prompt
            // never runs for these users.
            notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            if !viewModel.state.selectedEngine.isInstalled {
                showWindow()
            }
        }
    }

    private func showAuthGate(onContinue: @escaping () -> Void) {
        if authGateWindow == nil {
            authGateWindow = AuthGateWindow(account: accountStore) { [weak self] in
                self?.authGateWindow?.close()
                self?.authGateWindow = nil
                onContinue()
            }
        }
        authGateWindow?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Fire the launch-time analytics signals. No-ops entirely when the user
    /// hasn't opted in (the `Analytics` wrapper gates every send).
    private func reportLaunchAnalytics() {
        Analytics.shared.send(.appLaunched)
        Analytics.shared.send(.permissionState(
            accessibility: permissionsManager.accessibilityGranted(),
            microphone: permissionsManager.microphoneStatus() == .granted
        ))
        // Fired only on the first launch after an update; commits the version
        // regardless, so opting in later never reports a stale update.
        if let from = AnalyticsIdentity.consumeVersionChange() {
            Analytics.shared.send(.updateInstalled(from: from, to: AnalyticsIdentity.currentVersion))
        }
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

        // Reconcile the optional cleanup model with its toggle (edge-triggered
        // inside, so this is a no-op unless the user just flipped it).
        viewModel.reconcileCleanupModel()

        // Retract the "nowhere to paste" hint once its display window elapses.
        if let at = state.undeliveredTranscriptAt,
           Date().timeIntervalSince(at) >= AppState.undeliveredBannerDuration {
            state.undeliveredTranscriptAt = nil
        }

        // Retract the "learned a word" confirmation once its window elapses.
        if let at = state.learnedTermAt,
           Date().timeIntervalSince(at) >= AppState.learnedBannerDuration {
            state.learnedTerm = nil
            state.learnedTermAt = nil
        }

        // Retract the "smart cleanup is ready" confirmation once its window elapses.
        if let at = state.cleanupModelReadyAt,
           Date().timeIntervalSince(at) >= AppState.cleanupReadyBannerDuration {
            state.cleanupModelReadyAt = nil
        }

        // Sync the "keep this Mac awake for phone dictation" opt-in to the server.
        // `setKeepAwakeAlways` is transition-guarded, so calling it every tick is
        // cheap — the timer is our bridge from @Observable state to AppKit.
        transcriptionServer.setKeepAwakeAlways(state.keepAwakeForRemote)

        // Keep Apple Intelligence availability fresh so the Settings hint updates
        // live as the model finishes downloading. Only write on change.
        let aiStatus = AppleIntelligenceStatus.current
        if state.appleIntelligenceStatus != aiStatus {
            state.appleIntelligenceStatus = aiStatus
        }

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
            notes: notesStore,
            connectors: connectorStore,
            account: accountStore,
            reopenOnboarding: { [weak self] in self?.showOnboarding() },
            checkForUpdates: { [weak self] in self?.updaterController.checkForUpdates(nil) },
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
        // Light "Organic" chrome: cream titlebar that blends with the warm ground.
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Theme.canvasNSColor
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // No frame autosave: the window opens at a consistent default size every
        // time (applied in showWindow), rather than restoring a prior resize.
        self.window = window
    }

    /// Size the settings window to 80% of the screen's usable width and its full
    /// usable height, centered horizontally — applied on every open.
    private func applyDefaultWindowFrame(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = visible.width * 0.8
        let height = visible.height
        let origin = NSPoint(x: visible.minX + (visible.width - width) / 2, y: visible.minY)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
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
            Analytics.shared.send(.onboardingFinished)
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
        if let window { applyDefaultWindowFrame(window) }
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
            // Manual check: bring Sparkle's update window to the front.
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Scheduled check: post the gentle reminder. We don't gate on
            // background — as a regular Dock app the user usually HAS us active,
            // and `willPresent` makes the banner show in the foreground too.
            // Tapping it triggers the update (`didReceive`).
            postUpdateAvailableNotification(for: update)
        }
    }

    /// Clear the delivered reminder once the user engages with the update, so a
    /// stale notification doesn't linger (and the reused identifier can re-alert).
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.updateNotificationIdentifier])
    }

    private func postUpdateAvailableNotification(for update: SUAppcastItem) {
        let content = UNMutableNotificationContent()
        content.title = "Update available"
        content.body = "Whisper Master \(update.displayVersionString) is ready to install."
        let request = UNNotificationRequest(
            identifier: Self.updateNotificationIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    static let updateNotificationIdentifier = "app.whispermaster.update-available"

    /// Show the update banner even when the app is frontmost (otherwise macOS
    /// suppresses notifications for the active app).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tapping the update reminder kicks off the update flow.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == Self.updateNotificationIdentifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NSApp.activate(ignoringOtherApps: true)
            updaterController.checkForUpdates(nil)
        }
        completionHandler()
    }
}
