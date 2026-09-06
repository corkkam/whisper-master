import AppKit
import ClerkKit
import Sparkle
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    /// What the tray currently shows, so the same 0.5s loop only rebuilds the icon /
    /// rewrites the tooltip and menu header when the state behind them changed. The
    /// icon is keyed by SF Symbol name, with `""` standing for the brand logo.
    private var appliedTrayIconKey: String?
    private var appliedTrayTooltip: String?
    private var appliedTrayHeader: String?
    private var hotkeyManager: HotkeyManager?
    /// Watches the fn + control chord — "what I'm about to say goes to the
    /// assistant, not the cursor" (see `setupHotkey`).
    private var commandChordMonitor: ModifierChordMonitor?
    /// Watches the user-chosen key that talks to a coding agent. Nil whenever no key
    /// is chosen, or the chosen one collides with push-to-talk — a monitor for a key
    /// we would refuse to act on is a monitor that should not exist.
    private var agentHotkeyManager: HotkeyManager?
    /// The key `agentHotkeyManager` is currently installed for, so the reconcile on
    /// the refresh tick is a no-op unless the preference actually changed.
    private var installedAgentHotkey: HotkeyManager.HotkeyOption?
    /// Esc-to-dismiss for the agent bands. Two monitors because a global one never
    /// sees events while our own panel is key.
    private var escKeyMonitorGlobal: Any?
    private var escKeyMonitorLocal: Any?
    private let permissionsManager = PermissionsManager()
    private lazy var viewModel = DictationViewModel(
        hotkeyUpdater: { [weak self] hotkey in
            self?.hotkeyManager?.setHotkey(hotkey)
            self?.claimFnKeyIfChosen(hotkey)
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
    /// The hover quick-actions band. Watches the notch on its own slow timer and is
    /// only on screen while open, so it never sits over the menu bar.
    private var quickActionsWindow: NotchQuickActionsWindow?
    private var bluetoothInputMonitor: BluetoothInputMonitor?
    private var onboardingWindow: NotchOnboardingWindow?
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
    /// The coding-agent section of the tray menu, and the signature of what is
    /// currently drawn in it. Change-guarded like the history submenu: this is
    /// rebuilt on a 0.5s tick, and the answer is identical on nearly every one.
    private var agentsMenu: NSMenu?
    private var agentsMenuItem: NSMenuItem?
    private var renderedAgentRows: [String] = []

    /// Sparkle auto-updater. `startingUpdater: true` begins scheduled update
    /// checks (gated by `SUEnableAutomaticChecks` in Info.plist) against the
    /// `SUFeedURL` appcast, verified with the `SUPublicEDKey`.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Analytics first, because it installs the crash handler.
        //
        // The rest of this method is the launch work most likely to crash — the
        // engine graph, Metal warm-up, the MLX model — and a handler installed
        // after it would miss exactly the crashes worth catching. Read straight
        // from `UserDefaults` rather than `viewModel.state`, which would force
        // the lazy view model up here and reorder launch. No-op, and no handler,
        // when the user has analytics off.
        Analytics.shared.configure(enabled: AppState.persistedAnalyticsEnabled)

        // Did the *previous* run crash? Consumes the sentinel, then scans for the
        // OS's own report off-main. Must run before `markLaunch` overwrites it.
        CrashReporter.reportPreviousCrashIfNeeded()
        CrashReporter.markLaunch()

        // Configure Clerk before anything reads `Clerk.shared`. Sign-in gates
        // the whole app: the LAN transcription server, the mesh, onboarding, and
        // the settings window are all deferred until the user authenticates
        // (see reconcileAuthGate / proceedAfterAuthIfNeeded). No-op — and the app
        // stays locked with a setup message — if no publishable key is set.
        ClerkConfig.configureIfPossible()

        // Sync the Settings "Open at login" toggle with the OS Login Items state
        // (the user may have changed it in System Settings while we were quit) —
        // and re-register if an app update replaced the bundle and the OS dropped
        // the registration, which otherwise silently stops us opening at login.
        LaunchAtLogin.shared.reconcileOnLaunch()

        // The app is light-only — there is no dark mode and no appearance
        // preference. This has to be *pinned* rather than left alone: with a nil
        // appearance the windows inherit the Mac's setting, so a user in system
        // dark mode would get dark AppKit chrome (menus, text fields, scrollers,
        // focus rings) around our paper-ground tokens. Setting it on `NSApp`
        // cascades to every window we create, and the notch bands opt back out by
        // pinning `.darkAqua` on their own panels — they sit on the physical
        // bezel, which is a hardware fact rather than a mode.
        NSApp.appearance = NSAppearance(named: .aqua)

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

        // The launch signals themselves. `Analytics.shared.configure` already ran
        // at the top of this method (it installs the crash handler); this only
        // records the launch, which needs `permissionsManager` and so belongs
        // after setup.
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
            viewModel.state.connectorStore.activate(userID: "dev-local")
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
            viewModel.state.connectorStore.activate(userID: user.id)
            // Attach the account to analytics on the same reconcile that scopes the
            // stores, so the two can never disagree about who is signed in.
            // `identify` is idempotent, which it has to be — this runs twice a
            // second for the life of the session.
            Analytics.shared.identify(
                AnalyticsAccount(
                    id: user.id,
                    email: user.primaryEmailAddress?.emailAddress,
                    // Clerk leaves both name halves optional, and a first name with
                    // no last name is common; join what exists rather than
                    // rendering "Jane nil".
                    name: [user.firstName, user.lastName]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                )
            )
        } else if Clerk.shared.isLoaded {
            presentAuthGate()
            // Signed out — hide the app and drop the loaded account so neither the
            // UI nor their stats are visible behind the gate.
            hideAppSurfacesForGate()
            viewModel.state.usageStore.deactivate()
            viewModel.state.notesStore.deactivate()
            viewModel.state.connectorStore.deactivate()
            // Drop the person too, or the next user of this Mac inherits the last
            // one's profile.
            Analytics.shared.resetIdentity()
        }
        // Still loading a persisted session: leave the launch-time gate (which
        // shows a spinner) as-is until `isLoaded` resolves.
    }

    /// Bring up everything that was held behind the gate, exactly once, after
    /// the first successful sign-in. Signing out later just re-shows the gate;
    /// it doesn't tear these back down.
    /// Bring the remote transcription listener in line with the user's opt-in.
    ///
    /// Idempotent: `start()` returns early when already listening and `stop()`
    /// when already stopped, so this is safe to call on every refresh tick. That
    /// is how a Settings toggle takes effect without an app restart — and, more
    /// importantly, how switching it *off* actually closes the socket.
    private func reconcileRemoteServer() {
        if viewModel.state.remoteDictationEnabled {
            transcriptionServer.start()
        } else {
            transcriptionServer.stop()
        }
    }

    private func proceedAfterAuthIfNeeded() {
        guard !didProceedAfterAuth else { return }
        didProceedAfterAuth = true

        // Take the Globe key off macOS if that's the push-to-talk key. Here rather
        // than in `setupHotkey` deliberately: this writes a system-wide preference,
        // and doing that to someone who has only ever seen the sign-in gate would be
        // changing their Mac before they'd decided to use the app.
        claimFnKeyIfChosen(viewModel.state.hotkey)

        // Voice engine: download only if the model isn't already on disk, else
        // just load it. Runs in parallel with the single-step permissions
        // screen — model prep only needs the network, not mic/accessibility.
        viewModel.prepareDefaultEngineOnLaunch()

        // Advertise the LAN transcription service so a paired phone can stream
        // audio here and use this Mac's models — but only if the user asked for
        // it. This is opt-in (default off): it opens a listening socket, and it
        // used to start for every install unconditionally. `reconcileRemoteServer`
        // on the refresh tick picks up later toggles.
        reconcileRemoteServer()
        // Discover other Macs running Whisper Master on the network (the mesh).
        meshCoordinator.start()

        // Watch for coding agents on this Mac. Held behind the gate with the rest of
        // the bring-up, and dormant until now so `swift test` and the headless
        // snapshot renderer never open a socket. If no kunai answers on loopback the
        // poll finds nothing and the surface stays dark, which is the correct
        // outcome on almost every install.
        viewModel.state.agents.start()

        // Read the calendar and start ranking the day. Dormant until now for the
        // same reason `agents` is: building an `AppState` under `swift test` or the
        // headless renderer must not open an `EKEventStore` or arm a timer. With no
        // calendar grant it reads nothing and the ambient row simply never appears.
        viewModel.state.now.start()

        // Ask the appcast whether there is an update, without showing anything.
        // `checkForUpdateInformation()` is the one Sparkle entry point that has no
        // user driver behind it: it only fires the delegate callbacks below, which
        // set `availableUpdateVersion` and light the sidebar card. Held behind the
        // gate with the rest of the bring-up because `allowedChannels` reads the
        // signed-in user's flag, so a check made before the session loads would
        // miss the beta channel.
        updaterController.updater.checkForUpdateInformation()

        let userID = currentOnboardingUserID()

        // Migration for existing installs: they have no per-user onboarding
        // record. If the account has already granted the core permissions it's
        // plainly past onboarding — seed as seen so we don't re-show the wizard.
        if let userID, !OnboardingProgress.hasRecord(userID: userID),
           permissionsManager.microphoneStatus() == .granted,
           permissionsManager.accessibilityGranted() {
            OnboardingProgress.markSeen(OnboardingStep.allCases.map(\.id), userID: userID)
        }

        // Single-step permissions wizard once per account. Past that: quiet
        // notification prompt + open Settings if the model still needs install
        // (progress lives in Settings / the notch, not a done step).
        let pending = userID.map { OnboardingProgress.pendingSteps(userID: $0) } ?? OnboardingStep.allCases
        if !pending.isEmpty {
            showOnboarding(userID: userID)
        } else {
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
        viewModel.state.connectorStore.deactivate()
        // The day belongs to the account that was signed in — stop reading it and
        // clear what is held, or the next person to sign in sees the last one's
        // meetings on the bezel.
        viewModel.state.now.stop()
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
        // Nothing of the account's data may be reachable behind the gate, and the
        // band is made of exactly that.
        quickActionsWindow?.stop()
    }

    /// Bring the passive dictation pill back after a sign-in. The Settings window
    /// is intentionally left closed (the user opens it explicitly); only the
    /// always-present notch pill is restored.
    private func revealAppSurfacesAfterAuth() {
        guard appSurfacesHidden else { return }
        appSurfacesHidden = false
        pillWindow?.show()
        quickActionsWindow?.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the settings (or any) window must NOT quit — the menu-bar tray
        // and Dock icon are the persistent surface so dictation stays available
        // in the background (hotkeys, pill, mesh, model downloads). Minimize /
        // Hide / close all leave the process running; only Quit ends it.
        false
    }

    /// Silence any answer still being read aloud.
    ///
    /// **Not optional.** Speech plays out of process (`speechsynthesisd` for the system
    /// voice), so quitting mid-utterance can leave the Mac talking after the app is
    /// gone — with nothing left on screen to explain it or any way to stop it.
    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stopSpeaking()
        // Whatever we paused for a dictation goes back to playing — otherwise
        // quitting mid-session leaves the speakers silent with nothing left running
        // to explain why.
        viewModel.releaseHeldMedia()
        // The other half of crash detection. macOS calls this for ⌘Q, the tray
        // Quit item, and logout — but never for a crash, which is precisely the
        // discrimination `CrashReporter` relies on. A Force Quit skips it too and
        // is therefore reported as an unclean exit with `hasReport=false`.
        CrashReporter.markCleanExit()
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

        // **The agents' entry point that is not a shortcut.** The glance opens with a
        // user-chosen key that is off by default, so on a fresh install there was no
        // way to reach the sessions at all. The tray is always there, needs nothing
        // configured, and is where people already look to see what an app is doing.
        // It hides itself when kunai is not running, so a Mac without one is
        // unchanged.
        let agentsItem = NSMenuItem(title: "Coding Agents", action: nil, keyEquivalent: "")
        let agentsSub = NSMenu()
        agentsItem.submenu = agentsSub
        agentsItem.isHidden = true
        menu.addItem(agentsItem)
        agentsMenu = agentsSub
        agentsMenuItem = agentsItem

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

        // Hand the user's music back once the whole exchange is over (the pause itself
        // happens on the key press, in `startRecording`). **Above the tray guard on
        // purpose:** giving the speakers back cannot depend on the menu bar having a
        // status item — an early return there would leave the Mac silent with no way
        // to explain it.
        viewModel.reconcileMediaPlayback()

        guard let item = statusItem, let button = item.button else { return }
        let state = viewModel.state

        let (symbol, tooltip, headerText) = trayAppearance(for: state)
        // **Only write the tray icon when it actually changes.** This runs twice a
        // second for the life of the process; reassigning `button.image` every tick
        // built a fresh `NSImage` each time and pushed a status-item update through
        // the menu-bar server for a picture that is identical ~99% of ticks. Same
        // reasoning as the other `applied…` caches above. (`nil` symbol → the brand logo, the
        // calm idle/ready state; active states keep their SF Symbol so status stays
        // glanceable.) The key is cached only on a successful assignment, so a failed
        // image lookup is retried on the next tick rather than latched.
        let iconKey = symbol ?? ""
        if appliedTrayIconKey != iconKey {
            if let symbol, let image = Self.statusImage(symbol: symbol) {
                button.image = image
                appliedTrayIconKey = iconKey
            } else if symbol == nil, let logo = BrandAsset.trayTemplateImage(points: 18) {
                button.image = logo
                appliedTrayIconKey = iconKey
            }
        }
        if appliedTrayTooltip != tooltip {
            appliedTrayTooltip = tooltip
            button.toolTip = tooltip
        }
        if appliedTrayHeader != headerText {
            appliedTrayHeader = headerText
            statusHeader?.title = headerText
        }

        startItem?.isEnabled = state.canStart
        stopItem?.isEnabled = state.canStop
        cancelItem?.isHidden = state.preparingEngine == nil

        // The notch panel is click-through except while an interactive banner is
        // up — the Bluetooth-mic "use built-in" button, the tappable command
        // confirmation ("reminder set · tap to change"), a due reminder (tap to
        // open it), the undelivered hint's Copy button, or a write-approval
        // card — where clicks matter.
        pillWindow?.setInteractive(
            // The ambient row's checkbox and Join pill. This is the one entry here
            // that can be true for minutes at a stretch rather than for a beat, so
            // `DictationPillContent` marks the black fill and every non-control
            // part of the row non-hittable — otherwise the surface would swallow
            // menu-bar clicks for the whole ten minutes before a meeting.
            state.ambientRowTakesClicks
                || state.approvals.pending != nil
                // The nudge is a pointer to another session, so it has to be
                // tappable — a band that says "tap to answer" and swallows the tap
                // is worse than no band.
                || state.shouldShowAgentNudge
                || state.shouldShowAgentAsk
                || state.shouldShowAgentGlance
                || state.shouldShowAgentReply
                // The working row carries the stop button. Without this the window
                // stays click-through and a click on "stop" falls through to
                // whatever menu-bar item sits behind the band — which is how
                // pressing stop opened a menu-bar assistant instead.
                || state.shouldShowAgentWorking
                || state.shouldShowBluetoothBanner
                || state.shouldShowCommandConfirmation
                || state.shouldShowDueReminderBanner
                || state.shouldShowUndeliveredBanner)

        // Keep the optional coding-agent key in step with the preference, and give
        // the menu bar back once a revealed session has been read.
        reconcileAgentHotkey()
        if state.agents.revealHasExpired() { state.agents.closeGlance() }
        reconcileAgentNudge()

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

        // Retract a due reminder once its window elapses — but only count the time
        // it was actually on screen. A dictation (or an approval card) started
        // mid-window hides the band, and an alert the user never saw must not
        // expire silently behind whatever took the notch: while it's suppressed
        // the clock is pushed forward, so it restarts when the band comes back.
        if state.dueReminder != nil {
            if !state.canShowDueReminderBanner {
                state.dueReminderAt = Date()
            } else if let at = state.dueReminderAt,
                      Date().timeIntervalSince(at) >= state.dueReminderWindow {
                state.dueReminder = nil
                state.dueReminderAt = nil
                state.dueReminderCompleted = false
            }
        }

        // Retract the "nowhere to paste" hint once its display window elapses.
        if let at = state.undeliveredTranscriptAt,
           Date().timeIntervalSince(at) >= AppState.undeliveredBannerDuration {
            state.undeliveredTranscriptAt = nil
            state.undeliveredText = nil
        }

        // Retract the polished-transcript beat once its window elapses.
        if let at = state.polishedAt,
           Date().timeIntervalSince(at) >= AppState.polishedBeatDuration {
            state.polishedText = nil
            state.polishedAt = nil
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
           Date().timeIntervalSince(at) >= state.commandConfirmationWindow {
            state.commandConfirmation = nil
            state.commandConfirmationAt = nil
        }

        // Retract the success "delivered" checkmark once its brief window elapses
        // (nil-ing it drives the pill re-render + retract, like the hints above).
        if let at = state.deliveredAt,
           Date().timeIntervalSince(at) >= AppState.deliveredBeatDuration {
            state.deliveredAt = nil
        }

        // Retract the "what's my day" answer once its window elapses — but the clock
        // only runs while nobody is reading it aloud. Pinning `daySummaryAt` to now for
        // the length of the speech means the band holds for exactly as long as the voice
        // takes, and `daySummaryWindow` then leaves a short tail to finish reading it.
        // Same paused-clock trick as the due reminder above, for the same reason: a
        // window the user couldn't have finished must not expire behind them.
        if state.activeDaySummary != nil {
            if state.isSpeakingAnswer {
                state.daySummaryAt = Date()
            } else if let at = state.daySummaryAt,
                      Date().timeIntervalSince(at) >= state.daySummaryWindow {
                state.activeDaySummary = nil
                state.daySummaryAt = nil
                state.daySummaryWasSpoken = false
            }
        }

        // Backstop for the clock above: a speaking flag that never cleared would pin the
        // band open forever. Also enforces the utterance ceiling and applies a
        // voice/toggle change to whatever is playing right now. No-op most ticks, and it
        // deliberately doesn't construct a speaker for a user who never speaks answers.
        viewModel.reconcileSpeech()

        // Start/stop the listener as the remote-dictation opt-in changes, then
        // sync the "keep this Mac awake" opt-in. Both are transition-guarded, so
        // calling them every tick is cheap — the timer is our bridge from
        // @Observable state to AppKit.
        reconcileRemoteServer()
        transcriptionServer.setKeepAwakeAlways(state.keepAwakeForRemote)

        // Keep Apple Intelligence availability fresh so the Settings hint updates
        // live as the model finishes downloading. Only write on change.
        let aiStatus = AppleIntelligenceStatus.current
        if state.appleIntelligenceStatus != aiStatus {
            state.appleIntelligenceStatus = aiStatus
        }

        refreshHistoryMenu()
        refreshAgentsMenu()
    }

    /// Redraw the agents section, only when what it says has changed.
    private func refreshAgentsMenu() {
        guard let agentsMenu, let agentsMenuItem else { return }
        let controller = viewModel.state.agents
        let sessions = controller.sessions
        // Absent is the normal state: no kunai, no section. A greyed-out menu for a
        // server almost nobody runs is clutter on every other Mac.
        let visible = controller.isAvailable && !sessions.isEmpty
        if agentsMenuItem.isHidden == visible { agentsMenuItem.isHidden = !visible }
        guard visible else {
            if !renderedAgentRows.isEmpty {
                renderedAgentRows = []
                agentsMenu.removeAllItems()
            }
            return
        }

        let now = Date()
        let rows = sessions.map { "\($0.id)|\($0.repo)|\($0.statusLabel(now: now))" }
        // The elapsed stamp changes every second, so compare on the *state* rather
        // than the label — otherwise this rebuilds the menu twice a second forever,
        // which is exactly what the change guard exists to prevent.
        let signature = sessions.map {
            "\($0.id)|\($0.repo)|\($0.machineLabel)|\($0.state.rawValue)"
        }
        guard signature != renderedAgentRows else { return }
        renderedAgentRows = signature
        _ = rows

        agentsMenu.removeAllItems()
        for session in sessions {
            let item = NSMenuItem(
                title: Self.agentMenuTitle(for: session, now: now),
                action: #selector(openAgentSession(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            if session.state == .awaitingPermission {
                item.image = NSImage(
                    systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
            }
            agentsMenu.addItem(item)
        }
    }

    /// "whisper-master — Working 12s", or "kunai (linux) — Needs you" when the
    /// session is on another machine. The machine only appears when it is not this
    /// one, so the common case stays uncluttered.
    private static func agentMenuTitle(for session: AgentSession, now: Date) -> String {
        let name = session.repo.isEmpty ? "agent" : session.repo
        let where_ = session.isRemote ? " (\(session.machineLabel))" : ""
        return "\(name)\(where_) — \(session.statusLabel(now: now))"
    }

    /// Open one session on the band from the tray. Same door the nudge uses, so
    /// there is one way in and it behaves identically however it was reached.
    @objc private func openAgentSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        viewModel.state.agents.focus(sessionID: id)
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

    /// Keep the other-session nudge honest on the same tick everything else runs on.
    ///
    /// Two jobs, and they are opposites. While the band is busy the nudge's clock is
    /// **pinned**, because a window that runs down behind an approval card is a
    /// message the user never received. Once it has had its time on screen it is
    /// **dropped**, so a stale pointer cannot reappear the next time the band frees
    /// up. Same paused-clock shape the due reminder uses.
    private func reconcileAgentNudge() {
        let state = viewModel.state
        guard state.agents.nudge != nil else { return }
        guard state.canShowAgentNudge else {
            state.agents.holdNudge()
            return
        }
        guard let raisedAt = state.agents.nudgeAt else { return }
        if Date().timeIntervalSince(raisedAt) >= AgentSurfaceController.nudgeHold {
            state.agents.dismissNudge()
        }
    }

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
            // **The one agent state the menu bar reflects.** An agent blocked on a
            // permission you cannot see is the failure this whole feature exists to
            // prevent, and the tray is the surface that is always there — no
            // shortcut, no band, no timing. Everything else about the agents stays
            // in the notch, because a menu-bar icon that changed on every tool call
            // would be noise.
            if state.agents.otherSessionNeedsYou {
                return (
                    "hand.raised.fill", "Whisper Master — an agent needs you",
                    "An agent needs you")
            }
            if state.agents.runningSessionCount > 0 {
                let count = state.agents.runningSessionCount
                let label = count == 1 ? "1 agent working" : "\(count) agents working"
                return (nil, "Whisper Master — \(label)", label)
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
        // Appearance is pinned app-wide to `.aqua` in
        // `applicationDidFinishLaunching`, so the window inherits light without
        // pinning it here.
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
        pillWindow = DictationPillWindow(
            state: viewModel.state,
            onOpenNotes: { [weak self] in
                // Tapping the "reminder set · tap to change" banner opens Settings →
                // Notes & Reminders; the requested section is consumed by SettingsView.
                guard let self else { return }
                self.viewModel.state.requestedSettingsSection = .notes
                self.showWindow()
            },
            onCopyUndelivered: { [weak self] in
                // The Copy button on the "nowhere to type that" hint — hands over
                // the polished transcript when the on-device pass produced one.
                self?.viewModel.copyUndeliveredTranscript()
            },
            onToggleDueReminder: { [weak self] in
                // The checkbox on a reminder that just came due — ticks it off, or
                // puts it back if the tick was a misfire.
                self?.toggleDueReminder()
            },
            onCompleteNowReminder: { [weak self] id in
                // The checkbox on the ambient row: a reminder that is merely late,
                // not one that just fired. `refreshNow` follows the write because
                // the row is re-ranked on a one-minute tick, and waiting up to a
                // minute for it to leave reads as the tap having done nothing.
                guard let self else { return }
                self.viewModel.state.notesStore.completeReminder(id)
                self.viewModel.state.now.refreshNow()
            },
            onJoin: { [weak self] url in
                self?.openConferenceLink(url)
            })
        pillWindow?.show()

        // Resting the pointer on the notch opens the quick-actions band (reminders
        // + notes at a glance). It stays shut until a Clerk account is loaded (the
        // stores are empty before that) and whenever the dictation surface has
        // something of its own to say — see `AppState.notchIsOccupied`.
        quickActionsWindow = NotchQuickActionsWindow(
            state: viewModel.state,
            onJoin: { [weak self] url in
                self?.openConferenceLink(url)
            },
            onOpenNotes: { [weak self] request in
                guard let self else { return }
                self.viewModel.state.requestedSettingsSection = .notes
                // A composer can't live on the bezel panel (no key window, no text
                // field), so "New note" / "New reminder" open the real editor.
                self.viewModel.state.requestedNotesComposer = request
                self.showWindow()
            },
            onOpenSettings: { [weak self] in self?.showWindow() })
        quickActionsWindow?.start()

        // Watch for a Bluetooth mic input so the notch can offer to switch to
        // the built-in mic (keeps earphones in hi-fi). Read-only detection.
        bluetoothInputMonitor = BluetoothInputMonitor(state: viewModel.state)
        bluetoothInputMonitor?.start()
    }

    /// Take the Globe key off macOS when it's the push-to-talk key.
    ///
    /// The collision this removes is worst on the **hands-free double-tap**: with the
    /// stock "Press 🌐 key to: Show Emoji", latching hands-free popped the emoji
    /// picker open and shut, which steals focus from the very app the dictation is
    /// aimed at. Our monitors observe `flagsChanged` without consuming it — swallowing
    /// the key would take a HID-level tap that also breaks fn+F-key and fn+arrow — so
    /// the system preference is the only lever there is.
    ///
    /// Once, and only for fn: `FnKeyBehavior.claimFnKeyForPushToTalk` records the
    /// claim and the prior value, so a user who puts the emoji picker back keeps it,
    /// and Recording settings offers a one-click hand-back.
    private func claimFnKeyIfChosen(_ hotkey: HotkeyManager.HotkeyOption) {
        guard hotkey == .fn else { return }
        if FnKeyBehavior.claimFnKeyForPushToTalk() {
            Log.app.info("claimed the Globe key for push-to-talk (was: system behavior)")
            // Counted against the `restored: true` side, which is emitted from the
            // Settings hand-back button. A claim rate that is healthy and a restore
            // rate that is high together mean the claim is unwelcome — which is the
            // one thing that would say this feature should ask first.
            Analytics.shared.send(.fnKeyClaim(restored: false))
        }
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager(
            hotkey: viewModel.state.hotkey,
            // Hold to dictate; double-tap to keep dictating hands-free.
            latchesOnDoubleTap: true,
            holdToTalk: { [weak self] in self?.viewModel.state.holdToTalkEnabled ?? true }
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .start:
                // Gate dictation on sign-in AND waitlist acceptance: a press while
                // signed out surfaces the sign-in window; while not-yet-accepted,
                // the waitlist notice — instead of starting a recording.
                guard self.ensureCanDictate() else { return }
                self.viewModel.handleHotkeyStart()
            case .stop:
                self.viewModel.handleHotkeyStop()
            case .handsFree:
                self.viewModel.handleHotkeyHandsFree()
            case .toggle:
                guard self.ensureCanDictate() else { return }
                self.viewModel.handleHotkeyToggle()
            }
        }
        viewModel.hotkeyGestureReset = { [weak self] in
            self?.hotkeyManager?.resetGesture()
        }

        // **The assistant chord: hold fn + control.** This is the single way in to
        // every agent action and connector conversation — file a note or a reminder,
        // read the calendar, run a connector write, or just ask a question — and the
        // transcript is handled instead of typed. A chord rather than a key of its
        // own, because with the default fn push-to-talk it reads as "dictate, plus
        // control" — and it can therefore arm a recording that fn has *already*
        // started (the two presses are never simultaneous), which is why the view
        // model handles the edges rather than this closure. Same sign-in gate as
        // dictation.
        //
        // ⚠️ It is installed **here**, unconditionally, and must stay that way. It
        // spent a release nested inside `reconcileAgentHotkey()` below, downstream of
        // that function's two early returns — and since the coding-agent key is off by
        // default, the guard fired on every fresh install and the chord was never
        // created at all. fn + control simply dictated. The assistant does not depend
        // on the agent key, so nothing about its installation may.
        commandChordMonitor = ModifierChordMonitor(chord: .command) { [weak self] event in
            guard let self else { return }
            switch event {
            case .engaged:
                guard self.ensureCanDictate() else { return }
                self.viewModel.handleCommandChordEngaged()
            case .released:
                self.viewModel.handleCommandChordReleased()
            }
        }

        // The agent key is optional and user-chosen, so it is installed by the same
        // reconcile the refresh loop runs rather than once here.
        reconcileAgentHotkey()

        // Esc dismisses whatever agent band is up — the reply, the glance, the
        // working row. Observation, not consumption: a global monitor cannot
        // swallow the key, and does not need to; the band closing is the whole
        // effect. The turn itself keeps running server-side (the stop button on
        // the working row is what interrupts).
        escKeyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleEscIfAgentSurfaceShowing(event)
        }
        escKeyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleEscIfAgentSurfaceShowing(event)
            return event
        }
    }

    private func handleEscIfAgentSurfaceShowing(_ event: NSEvent) {
        guard event.keyCode == 53 else { return }
        let state = viewModel.state
        guard state.shouldShowAgentReply || state.shouldShowAgentGlance
            || state.shouldShowAgentWorking
        else { return }
        state.agents.closeGlance()
    }

    /// Install, move or remove the coding-agent key to match the preference.
    ///
    /// Change-guarded like everything else on the 0.5s path: this runs twice a second
    /// for the life of the process and the answer is identical on nearly every tick.
    ///
    /// A key that collides with push-to-talk resolves to `nil` (see
    /// `AppState.effectiveAgentHotkey`) and the monitor comes down, rather than two
    /// monitors fighting over one physical key — dictation wins, because it is the
    /// thing the app is for.
    private func reconcileAgentHotkey() {
        let wanted = viewModel.state.effectiveAgentHotkey
        guard wanted != installedAgentHotkey else { return }
        installedAgentHotkey = wanted

        guard let wanted else {
            agentHotkeyManager = nil
            return
        }
        if let agentHotkeyManager {
            agentHotkeyManager.setHotkey(wanted)
            return
        }
        // Same claim as push-to-talk: with the stock "Press 🌐 to show Emoji", every
        // press of the agent key would also open the emoji picker and steal focus
        // from the app the user is watching.
        claimFnKeyIfChosen(wanted)

        agentHotkeyManager = HotkeyManager(
            hotkey: wanted,
            // No hands-free latch: a held key that keeps listening after release is
            // right for typing a paragraph, and wrong for a key whose release is what
            // sends the words somewhere.
            latchesOnDoubleTap: false,
            holdToTalk: { true }
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .start:
                guard self.ensureCanDictate() else { return }
                self.viewModel.handleAgentKeyStart()
            case .stop:
                self.viewModel.handleAgentKeyStop()
            case .handsFree, .toggle:
                break
            }
        }
    }

    /// Present first-run setup **in the notch** (`NotchOnboardingWindow`), so the
    /// permissions are granted on the same surface dictation will use.
    ///
    /// The dictation pill is hidden while it's up: both panels anchor to the notch
    /// and the engine download that starts at launch would otherwise draw its
    /// progress band straight through the onboarding one.
    private func showOnboarding(userID: String? = nil) {
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

        pillWindow?.hide()
        // Onboarding owns the notch for the duration; the hover band must not open
        // through it (both anchor to the same strip).
        quickActionsWindow?.suspend()

        onboardingWindow = NotchOnboardingWindow(
            state: viewModel.state,
            permissions: permissionsManager,
            onOpenSettings: { [weak self] in self?.showWindow() },
            onClose: { [weak self] in
                // User dismissed early — drop to the tray. Mark it seen so it
                // doesn't reopen every launch; they can still reopen it via
                // the "Reopen Onboarding…" menu item.
                guard let self else { return }
                markSeen()
                self.dismissOnboarding()
                // Keep engine prep going (download-if-missing / load-if-present).
                self.viewModel.prepareDefaultEngineOnLaunch()
            },
            onComplete: { [weak self] in
                guard let self else { return }
                markSeen()
                self.dismissOnboarding()
                Analytics.shared.send(.onboardingFinished)
                // Notifications used to be their own step; prompt quietly now.
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                // Engine prep was kicked off at launch; this is idempotent — if the
                // model is already on disk it just loads, never re-downloads.
                self.viewModel.prepareDefaultEngineOnLaunch()
                self.showWindow()
            }
        )
        onboardingWindow?.show()
    }

    /// Tear the onboarding band down and give the notch back to the dictation
    /// pill — unless the sign-in gate is up, which owns surface visibility.
    private func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        if !appSurfacesHidden {
            pillWindow?.show()
            quickActionsWindow?.resume()
        }
    }

    @objc
    private func showWindow() {
        // The whole app is gated: while signed out, any path to Settings (tray,
        // Dock menu, Dock-icon reopen, ⌘,) surfaces the sign-in window instead.
        guard isSignedIn else {
            presentAuthGate()
            return
        }
        // Re-sync Login Items in case the user flipped it in System Settings.
        LaunchAtLogin.shared.refresh()
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
    /// Admit beta appcast items for a user carrying the Clerk `betaAccess` flag.
    /// Sparkle calls this on the main thread before every check, so it tracks the
    /// *current* Clerk session: a flag flipped server-side moves the user between
    /// the tracks on the next check, with no relaunch and no reinstall.
    ///
    /// ⚠️ This replaced a `feedURLString(for:)` override that pointed beta users
    /// at a second appcast. That could never work: the beta feed served a
    /// re-badged `…mac.beta` bundle, and Sparkle rejects an archive whose bundle
    /// neither matches the host's file name nor its bundle id, so the update was
    /// offered, downloaded, and then refused. One feed plus a channel tag is the
    /// mechanism Sparkle actually provides for this. There is no feed override
    /// now — `SUFeedURL` in Info.plist is correct for stable and beta alike, and
    /// `Scripts/channel.sh` bakes the dev feed into the dev bundle.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { BetaAccess.allowedChannels }
    }

    /// Light the sidebar's update card. Sparkle calls this for **every** kind of
    /// check — the silent `checkForUpdateInformation()` below, the scheduled
    /// background check, and a manual one — so the card appears without any
    /// window being thrown at the user, which is the whole point of it.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            viewModel.state.availableUpdateVersion = item.displayVersionString
        }
    }

    /// Put the card away again when the feed says this build is current — the
    /// user updated from somewhere else, or the release was pulled.
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { viewModel.state.availableUpdateVersion = nil }
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
    /// each fired so it alerts once; each style takes over its own surface — the
    /// notch band or the alarm window — one at a time, and a reminder that can't
    /// have that busy surface stays due and re-fires when it frees up.
    private func fireDueReminders() {
        let store = viewModel.state.notesStore
        for reminder in store.dueReminders(asOf: Date()) {
            switch reminder.alertStyle {
            case .notification:
                // The notch is where everything else this app says lands, so a
                // reminder announces itself there too rather than in Notification
                // Centre. Same busy rule as the alarm: only mark it fired once the
                // band has actually taken it.
                //
                // Order matters: the band keeps `reminder` as the pre-`markFired`
                // snapshot, which is what un-ticking its checkbox restores.
                if presentReminderInNotch(reminder) {
                    store.markFired(reminder.id)
                }
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

    /// Drop a due reminder into the notch, with its chosen sound. Returns false
    /// when the band can't take it right now — one announcement at a time, and it
    /// yields to the surfaces `AppState.canShowDueReminderBanner` names — in which
    /// case the caller leaves the reminder due so it re-fires on a later tick.
    @discardableResult
    private func presentReminderInNotch(_ reminder: ReminderItem) -> Bool {
        let state = viewModel.state
        guard state.dueReminder == nil, state.canShowDueReminderBanner else { return false }
        state.dueReminder = reminder
        state.dueReminderAt = Date()
        state.dueReminderCompleted = false
        Feedback.reminderDue(soundName: reminder.soundName)
        return true
    }

    /// The due-reminder banner's checkbox, both ways.
    ///
    /// Ticking goes through `completeReminder`, so a repeating reminder rolls to
    /// its next occurrence rather than being retired. Un-ticking hands back the
    /// Open a meeting's conference link.
    ///
    /// Re-checked against `ConferenceLink.isJoinable` at the point of opening, not
    /// only where it was extracted. The URL travels from an event body through a
    /// value type and a SwiftUI closure to get here, and `NSWorkspace.open` will
    /// happily launch a `file://` or a custom scheme — so the allowlist is applied
    /// again at the one call that acts on it. A link that fails the check is
    /// dropped silently: the button is only ever drawn for one that passed, so a
    /// failure here means something upstream is wrong rather than that the user
    /// needs telling.
    private func openConferenceLink(_ url: URL) {
        guard ConferenceLink.isJoinable(url) else {
            Log.app.error("Refused to open a non-conference link from the notch")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// snapshot the band has been holding since it fired — the only copy of the
    /// occurrence a repeat's roll-forward moved past.
    private func toggleDueReminder() {
        let state = viewModel.state
        guard let reminder = state.dueReminder else { return }
        if state.dueReminderCompleted {
            state.notesStore.restoreReminder(reminder)
            state.dueReminderCompleted = false
        } else {
            state.notesStore.completeReminder(reminder.id)
            state.dueReminderCompleted = true
        }
        // Restart the hold from the answer, so the undo window is measured from the
        // tick rather than from whatever was left of the announcement.
        state.dueReminderAt = Date()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Sparkle's gentle update reminder is the **only** thing this app posts to
    /// Notification Centre. Reminders coming due are announced in the notch
    /// (`presentReminderInNotch`) or by the alarm window.
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
        let identifier = response.notification.request.identifier
        if identifier == Self.updateNotificationIdentifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NSApp.activate(ignoringOtherApps: true)
            updaterController.checkForUpdates(nil)
        }
        completionHandler()
    }
}
