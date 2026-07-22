import AppKit
import ClerkKit
import Sparkle
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hotkeyManager: HotkeyManager?
    /// The dedicated "ask about my day" push-to-talk monitor (see `setupHotkey`).
    private var dayQueryHotkeyManager: HotkeyManager?
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
    /// Background backup of usage rollups to the dashboard. Clerk-free itself —
    /// we inject the signed-in identity here (App layer owns auth). Driven off
    /// the refresh loop; the local `usageStore` is always the source of truth.
    private lazy var usageSync = UsageSyncClient(
        store: viewModel.state.usageStore,
        identity: { [weak self] in await self?.currentUsageIdentity() }
    )
    /// Background backup + cross-device pull of notes & reminders. Same identity
    /// injection as usage sync; local `notesStore` is the source of truth.
    private lazy var notesSync = NotesSyncClient(
        store: viewModel.state.notesStore,
        identity: { [weak self] in await self?.currentUsageIdentity() }
    )
    /// Owns the single looping-alarm alert window. Created lazily on first fire.
    private let alarmController = AlarmController()
    private var pillWindow: DictationPillWindow?
    private var bluetoothInputMonitor: BluetoothInputMonitor?
    private var onboardingWindow: OnboardingWindow?
    /// The launch sign-in gate. Nil until first shown; reused thereafter.
    private var authGateWindow: AuthGateWindow?
    /// Latched once the user first authenticates, so the post-sign-in bring-up
    /// (LAN server, mesh, onboarding, settings window) runs exactly once.
    private var didProceedAfterAuth = false
    /// Set when the user taps **Sign Out**. Overrides the dev-build auth bypass
    /// so an explicit sign-out actually re-gates the app (otherwise the reconcile
    /// tick would immediately let a `.dev` build back in). Cleared on the next
    /// real sign-in. In-memory only, so a relaunch restores the dev convenience.
    private var userDidSignOut = false
    /// True while the app's own windows (Settings, dictation pill) are hidden
    /// behind the sign-in gate. Tracks the gated↔ungated transition so we hide /
    /// reveal them exactly once instead of every 0.5s reconcile tick.
    private var appSurfacesHidden = false
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
        updaterDelegate: self,
        userDriverDelegate: self
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure Clerk before anything reads `Clerk.shared`. Sign-in gates
        // the whole app: the LAN transcription server, the mesh, onboarding, and
        // the settings window are all deferred until the user authenticates
        // (see reconcileAuthGate / proceedAfterAuthIfNeeded). No-op — and the app
        // stays locked with a setup message — if no publishable key is set.
        ClerkConfig.configureIfPossible()

        setupMainMenu()
        setupStatusItem()
        setupWindow()
        setupPill()
        setupHotkey()
        startStatusRefreshLoop()

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

        // Note: the voice-engine model download is deliberately NOT started here.
        // It's held behind the sign-in gate and kicked from `proceedAfterAuthIfNeeded`
        // after the first successful sign-in — so a user who never signs in never
        // pulls the multi-hundred-MB model, and the download begins in parallel
        // with onboarding once they're in.

        // Dev-only: when WM_EVAL_CASES is set, grade the real pipeline over those
        // cases and write results.json, then leave the app running for inspection.
        if ProcessInfo.processInfo.environment["WM_EVAL_CASES"] != nil {
            Task { await EvalRunner.runIfRequested() }
        }

        // Anonymous, opt-in usage analytics (off unless the user enabled it in
        // Settings). Configure from the persisted flag, then record this launch.
        Analytics.shared.configure(enabled: viewModel.state.analyticsEnabled)
        reportLaunchAnalytics()

        // Put up the sign-in gate. At cold launch there's never a live session
        // yet (Clerk restores it asynchronously), so this always shows; the
        // refresh-loop reconcile then either dismisses it — proceeding to
        // onboarding/settings — the moment a persisted session loads, or leaves
        // it up showing Clerk's sign-in UI.
        // Dev build skips the gate; don't even flash the sign-in window.
        if !authBypassEnabled {
            presentAuthGate()
        }
        reconcileAuthGate()
    }

    /// True once the user is signed in with a real Clerk session. Everything
    /// that lets the user actually dictate is gated on this.
    private var isSignedIn: Bool {
        authBypassEnabled || (ClerkConfig.isConfigured && Clerk.shared.user != nil)
    }

    /// Dev-only escape from the sign-in gate, so the whole app can be exercised
    /// without a Clerk account. True **only** in the locally re-badged dev build
    /// (bundle id ends in ".dev", produced by `Scripts/dev-install.sh`); the
    /// shipping build's id is `app.whispermaster.mac`, so this is always false in
    /// production and the real gate is completely untouched. Set `WM_REQUIRE_AUTH=1`
    /// to force the real gate back on even in the dev build (to test sign-in).
    private var authBypassEnabled: Bool {
        // An explicit sign-out defeats the bypass so the gate can actually return.
        guard !userDidSignOut else { return false }
        guard (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev") else { return false }
        return ProcessInfo.processInfo.environment["WM_REQUIRE_AUTH"] != "1"
    }

    /// Identity for the usage-sync client: the Clerk user id plus a fresh session
    /// token (best-effort — a nil token falls back to the dashboard's shared-token
    /// gate). Returns nil when not signed in, so sync silently no-ops until then.
    private func currentUsageIdentity() async -> (userId: String, token: String?)? {
        guard ClerkConfig.isConfigured, let user = Clerk.shared.user else { return nil }
        let token: String? = try? await Clerk.shared.session?.getToken()
        return (user.id, token)
    }

    /// Show the blocking sign-in window (idempotent — never steals focus if it's
    /// already up, so the 0.5s reconcile tick can call it freely).
    private func presentAuthGate() {
        if authGateWindow == nil {
            authGateWindow = AuthGateWindow(onRetry: { [weak self] in
                // Re-attempt configuration (idempotent) and re-evaluate the gate,
                // so the offline/not-loaded Retry button actually tries again.
                ClerkConfig.configureIfPossible()
                self?.reconcileAuthGate()
            })
        }
        guard let gate = authGateWindow, !gate.isVisible else { return }
        gate.show()
    }

    /// Gate for the two dictation entry points (hotkey + tray): a press while
    /// signed out surfaces the auth gate instead of recording. (Reconstructed
    /// after data loss from session transcripts; the Supabase waitlist check that
    /// once lived here was removed before the crash, leaving the sign-in gate.)
    private func ensureCanDictate() -> Bool {
        guard isSignedIn else { presentAuthGate(); return false }
        return true
    }

    /// Reconcile the gate against the current Clerk session. Driven both once at
    /// launch and from the 0.5s status refresh loop (our @Observable→AppKit
    /// bridge), so sign-in/sign-out flip the gate without any Clerk callback.
    private func reconcileAuthGate() {
        // Dev build: skip the gate entirely and go straight into the app.
        if authBypassEnabled {
            authGateWindow?.close()
            proceedAfterAuthIfNeeded()
            viewModel.state.usageStore.activate(userID: "dev-local")
            viewModel.state.notesStore.activate(userID: "dev-local")
            return
        }
        // No key configured, or a definitively signed-out session → stay gated.
        guard ClerkConfig.isConfigured else { presentAuthGate(); hideAppSurfacesForGate(); return }
        if let user = Clerk.shared.user {
            // A real sign-in clears the manual sign-out latch (restores the dev
            // bypass for the next launch) and reveals the app again.
            userDidSignOut = false
            authGateWindow?.close()
            proceedAfterAuthIfNeeded()
            revealAppSurfacesAfterAuth()
            // Scope usage stats to this account (idempotent — only reloads on a
            // change), so the Insights dashboard shows just their numbers.
            viewModel.state.usageStore.activate(userID: user.id)
            viewModel.state.notesStore.activate(userID: user.id)
        } else if Clerk.shared.isLoaded {
            presentAuthGate()
            // Signed out — hide the app and drop the loaded account so neither the
            // UI nor their stats are visible behind the gate.
            hideAppSurfacesForGate()
            viewModel.state.usageStore.deactivate()
            viewModel.state.notesStore.deactivate()
        }
        // Still loading a persisted session: leave the launch-time gate (which
        // shows a spinner) as-is until `isLoaded` resolves.
    }

    /// Bring up everything that was held behind the gate, exactly once, after
    /// the first successful sign-in. Signing out later just re-shows the gate;
    /// it doesn't tear these back down.
    private func proceedAfterAuthIfNeeded() {
        guard !didProceedAfterAuth else { return }
        didProceedAfterAuth = true

        // Start downloading/loading the voice engine now (held behind the gate).
        // Model prep only needs the network, not the mic/accessibility permissions
        // the wizard collects, so it runs in parallel with onboarding — ideally
        // ready by the time the user reaches the last step.
        viewModel.prepareDefaultEngineOnLaunch()

        // Advertise the LAN transcription service so iOS clients can stream
        // audio here and use this Mac's models.
        transcriptionServer.start()
        // Discover other Macs running Whisper Master on the network (the mesh).
        meshCoordinator.start()

        let userID = currentOnboardingUserID()

        // Migration for existing installs: they have no per-user onboarding
        // record. If the account has already granted the core permissions it's
        // plainly past onboarding — seed the current steps as seen so we don't
        // re-run the whole wizard once. Only genuinely new future steps surface.
        if let userID, !OnboardingProgress.hasRecord(userID: userID),
           permissionsManager.microphoneStatus() == .granted,
           permissionsManager.accessibilityGranted() {
            OnboardingProgress.markSeen(OnboardingStep.allCases.map(\.id), userID: userID)
        }

        // Show onboarding once per account, and thereafter only the steps this
        // account hasn't seen yet (e.g. a step added in a later version). No
        // account id (shouldn't happen post-auth) → fall back to the full flow.
        let pending = userID.map { OnboardingProgress.pendingSteps(userID: $0) } ?? OnboardingStep.allCases
        if !pending.isEmpty {
            showOnboarding(steps: pending, userID: userID)
        } else {
            // Past onboarding (it won't show), so ask for notification permission
            // here — the onboarding step that normally owns the prompt never runs.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            if !viewModel.state.selectedEngine.isInstalled {
                showWindow()
            }
        }
    }

    /// The account onboarding progress is scoped to: the signed-in Clerk user,
    /// or `dev-local` when the dev build bypasses the auth gate. Mirrors the
    /// identity `usageStore.activate(userID:)` uses.
    private func currentOnboardingUserID() -> String? {
        if let id = Clerk.shared.user?.id { return id }
        if authBypassEnabled { return "dev-local" }
        return nil
    }

    /// Sign the current user out. The refresh-loop reconcile then re-presents the
    /// gate once the session clears; we also present it immediately so there's no
    /// half-second window where the app looks usable.
    @objc
    private func signOut() {
        // Latch first so the dev-build bypass can't immediately let us back in,
        // then hide the app and show the gate right away — no half-second window
        // where the app still looks usable while the network sign-out is in flight.
        userDidSignOut = true
        hideAppSurfacesForGate()
        presentAuthGate()
        viewModel.state.usageStore.deactivate()
        viewModel.state.notesStore.deactivate()
        Task {
            do {
                try await Clerk.shared.auth.signOut()
            } catch {
                Log.auth.error("Sign out failed: \(error.localizedDescription, privacy: .public)")
            }
            // Reconcile picks up the cleared session on the next tick and keeps
            // the gate up (the latch holds it there even in a dev build).
            self.reconcileAuthGate()
        }
    }

    /// Hide every app surface so nothing is viewable behind the sign-in gate.
    /// Idempotent via `appSurfacesHidden`, so the 0.5s reconcile tick can call it
    /// freely while signed out. The pill/onboarding may not exist yet at cold
    /// launch (they're created post-auth) — the optionals no-op in that case.
    private func hideAppSurfacesForGate() {
        guard !appSurfacesHidden else { return }
        appSurfacesHidden = true
        window?.orderOut(nil)
        onboardingWindow?.close()
        pillWindow?.hide()
    }

    /// Bring the passive dictation pill back after a sign-in. The Settings window
    /// is intentionally left closed (the user opens it explicitly); only the
    /// always-present notch pill is restored.
    private func revealAppSurfacesAfterAuth() {
        guard appSurfacesHidden else { return }
        appSurfacesHidden = false
        pillWindow?.show()
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
                title: "Sign Out",
                action: #selector(signOut),
                keyEquivalent: ""
            )
        )
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
        // Flip the sign-in gate in step with the Clerk session — this timer is
        // our bridge from Clerk's @Observable state to AppKit, same as for
        // AppState below.
        reconcileAuthGate()

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

        // The notch panel is click-through except while an interactive banner is
        // up — the Bluetooth-mic "use built-in" button, or the tappable command
        // confirmation ("reminder set · tap to change") — where clicks matter.
        pillWindow?.setInteractive(state.shouldShowBluetoothBanner || state.shouldShowCommandConfirmation)

        // Drive gentle reminders off the same poll — a cheap, idle-gated check.
        viewModel.evaluateReminders()

        // Reconcile the optional cleanup model with its toggle (edge-triggered
        // inside, so this is a no-op unless the user just flipped it).
        viewModel.reconcileCleanupModel()

        // Mirror any changed usage rollups to the cloud (debounced + single-
        // flight inside; no-ops when the toggle is off, offline, or nothing
        // changed). The local store already has the data — this is just backup.
        usageSync.syncIfNeeded(enabled: state.usageSyncEnabled)

        // Notes & reminders: pull the account's items once per activation (so a
        // second Mac catches up), then mirror local changes up. Both are debounced
        // + single-flight inside; no-ops when the toggle is off or nothing changed.
        notesSync.pullIfNeeded(enabled: state.notesSyncEnabled)
        notesSync.syncIfNeeded(enabled: state.notesSyncEnabled)

        // Fire any reminders that have come due (poll-driven — the app is a
        // persistent menu-bar process, so this is the reliable path).
        fireDueReminders()

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

        // Retract the "note saved / reminder set" confirmation once its window
        // elapses (nil-ing both fields drives the pill re-render + retract).
        if let at = state.commandConfirmationAt,
           Date().timeIntervalSince(at) >= AppState.commandConfirmationDuration {
            state.commandConfirmation = nil
            state.commandConfirmationAt = nil
        }

        // Retract the success "delivered" checkmark once its brief window elapses
        // (nil-ing it drives the pill re-render + retract, like the hints above).
        if let at = state.deliveredAt,
           Date().timeIntervalSince(at) >= AppState.deliveredBeatDuration {
            state.deliveredAt = nil
        }

        // Retract the "what's my day" answer once its (longer) window elapses.
        if let at = state.daySummaryAt,
           Date().timeIntervalSince(at) >= AppState.daySummaryDuration {
            state.activeDaySummary = nil
            state.daySummaryAt = nil
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
            reopenOnboarding: { [weak self] in self?.showOnboarding() },
            checkForUpdates: { [weak self] in self?.updaterController.checkForUpdates(nil) },
            startSetup: { [weak self] in self?.viewModel.prepareSelectedEngineInBackground() },
            cancelSetup: { [weak self] in self?.viewModel.cancelModelPreparation() },
            signOut: { [weak self] in self?.signOut() }
        )
        // Inject the shared Clerk instance so the Account panel can read the
        // signed-in user reactively (same source the auth gate observes).
        let host = NSHostingController(rootView: rootView.environment(Clerk.shared))

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
        pillWindow = DictationPillWindow(state: viewModel.state) { [weak self] in
            // Tapping the "reminder set · tap to change" banner opens Settings →
            // Notes & Reminders; the requested section is consumed by SettingsView.
            guard let self else { return }
            self.viewModel.state.requestedSettingsSection = .notes
            self.showWindow()
        }
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
                // Gate dictation on sign-in AND waitlist acceptance: a press while
                // signed out surfaces the sign-in window; while not-yet-accepted,
                // the waitlist notice — instead of starting a recording.
                guard self.ensureCanDictate() else { return }
                self.viewModel.handleHotkeyPressed()
            case .released:
                self.viewModel.handleHotkeyReleased()
            }
        }

        // The dedicated "ask about my day" push-to-talk: a separate key that
        // always routes the finished transcript to the connectors (answered in the
        // notch) instead of pasting it. Same sign-in gate as dictation.
        dayQueryHotkeyManager = HotkeyManager(hotkey: viewModel.state.dayQueryHotkey) { [weak self] event in
            guard let self else { return }
            switch event {
            case .pressed:
                guard self.ensureCanDictate() else { return }
                self.viewModel.handleDayQueryHotkeyPressed()
            case .released:
                self.viewModel.handleDayQueryHotkeyReleased()
            }
        }
        viewModel.dayQueryHotkeyUpdater = { [weak self] hotkey in
            self?.dayQueryHotkeyManager?.setHotkey(hotkey)
        }
    }

    private func showOnboarding(
        steps: [OnboardingStep] = OnboardingStep.allCases,
        userID: String? = nil
    ) {
        if let onboardingWindow {
            onboardingWindow.show()
            return
        }

        // Whoever we present to, record the whole current flow as seen once they
        // finish or dismiss — so it opens once per account and only future new
        // steps reappear. Resolve the id now (menu reopens pass none).
        let seenUserID = userID ?? currentOnboardingUserID()
        let markSeen: () -> Void = {
            if let seenUserID {
                OnboardingProgress.markSeen(OnboardingStep.allCases.map(\.id), userID: seenUserID)
            }
        }

        onboardingWindow = OnboardingWindow(
            state: viewModel.state,
            permissions: permissionsManager,
            microphoneCapture: onboardingMic,
            steps: steps,
            retryEngine: { [weak self] in self?.viewModel.prepareDefaultEngineOnLaunch() },
            onClose: { [weak self] in
                // User dismissed onboarding early — drop to the tray. Mark it seen
                // so it doesn't reopen every launch; they can still reopen it via
                // the "Reopen Onboarding…" menu item.
                guard let self else { return }
                markSeen()
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
            }
        ) { [weak self] in
            guard let self else { return }
            markSeen()
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
        // The whole app is gated: while signed out, any path to Settings (tray,
        // Dock menu, Dock-icon reopen, ⌘,) surfaces the sign-in window instead.
        guard isSignedIn else {
            presentAuthGate()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window { applyDefaultWindowFrame(window) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    @objc
    private func showOnboardingFromMenu() {
        guard isSignedIn else {
            presentAuthGate()
            return
        }
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
        guard ensureCanDictate() else { return }
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

extension AppDelegate: SPUUpdaterDelegate {
    /// Choose the appcast feed dynamically from the signed-in user's beta flag.
    /// Sparkle calls this on the main thread before every check, so it always
    /// tracks the *current* Clerk session: a beta user (or one just flipped
    /// stable server-side) lands on the right feed without a relaunch. Returning
    /// nil would fall back to the static `SUFeedURL` in Info.plist; we always
    /// return a concrete channel so the two never drift.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { BetaAccess.currentChannel.feedURLString }
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

    // MARK: - Reminders

    /// Alert any reminders that have come due (called each refresh tick). Marks
    /// each fired so it alerts once; the alarm style takes over the alarm window
    /// (one at a time — a reminder that can't take the busy surface stays due and
    /// re-fires when it frees up).
    private func fireDueReminders() {
        let store = viewModel.state.notesStore
        for reminder in store.dueReminders(asOf: Date()) {
            switch reminder.alertStyle {
            case .notification:
                postReminderNotification(reminder)
                store.markFired(reminder.id)
            case .alarm:
                // The alarm rings until the user acts: Snooze pushes it out, Done
                // completes it (or re-arms a repeat). We deliberately DON'T
                // `markFired` here — the busy guard (`present` returns false while
                // an alarm is up) stops re-fires, and the user's action is what
                // clears the due state. Marking fired too would double-advance a
                // repeating reminder (once on fire, again on Done).
                let id = reminder.id
                alarmController.present(
                    reminder,
                    onSnooze: { [weak self] in self?.viewModel.state.notesStore.snoozeReminder(id, by: 5 * 60) },
                    onDone: { [weak self] in self?.viewModel.state.notesStore.completeReminder(id) }
                )
            }
        }
    }

    private func postReminderNotification(_ reminder: ReminderItem) {
        let content = UNMutableNotificationContent()
        content.title = reminder.displayTitle
        let body = reminder.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { content.body = body }
        content.sound = UNNotificationSound(named: .init("\(ReminderSound.resolved(reminder.soundName)).aiff"))
        let request = UNNotificationRequest(
            identifier: "\(Self.reminderNotificationPrefix)\(reminder.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    static let updateNotificationIdentifier = "app.whispermaster.update-available"
    static let reminderNotificationPrefix = "app.whispermaster.reminder."

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
        let identifier = response.notification.request.identifier
        if identifier == Self.updateNotificationIdentifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NSApp.activate(ignoringOtherApps: true)
            updaterController.checkForUpdates(nil)
        } else if identifier.hasPrefix(Self.reminderNotificationPrefix),
                  response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // Tapping a reminder opens the app (Notes & Reminders lives in Settings).
            showWindow()
        }
        completionHandler()
    }
}
