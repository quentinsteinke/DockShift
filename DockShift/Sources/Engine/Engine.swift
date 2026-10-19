// Engine.swift — DockShift
// The single reconciler that owns every side effect. It turns (Focus profile, current desktop,
// rules) into a Dock layout and per-display / per-Space wallpapers, and decides when restarting
// the Dock is safe. Everything is main-actor isolated; the only long operations (Dock restart +
// verify, per-Space wallpaper writes) are awaited, so the menu and window stay responsive.
import AppKit
import Observation

enum DockActivity: Equatable, Sendable {
    case idle, paused
    case waiting(String)       // e.g. "Waiting for Desktop 2 to settle"
    case applying(String)      // profile name
    case failed(String)
    case throttled             // circuit breaker tripped
}

enum ReconcileReason: String, Sendable {
    case launch, focusChanged, desktopChanged, rulesChanged, topologyChanged, wake, manual
}

enum EngineError: Error, LocalizedError {
    case profileNotFound, dockBusy, noScreen, wallpaperUnreadable

    var errorDescription: String? {
        switch self {
        case .profileNotFound: return "That profile no longer exists."
        case .dockBusy: return "DockShift is changing the Dock right now. Try again in a moment."
        case .noScreen: return "No display is available."
        case .wallpaperUnreadable:
            return "The current wallpaper can't be saved. Live, Aerial and dynamic wallpapers aren't supported — choose an image file instead."
        }
    }
}

/// What "New Profile" from the current setup made. `note` says what it left out and why
/// (e.g. no wallpaper because the desktops show different ones), for the sheet to show.
struct CreatedProfile: Sendable {
    var profile: Profile
    var note: String?
}

@MainActor @Observable final class Engine {
    static let shared = Engine()

    private(set) var started = false
    private(set) var spacesAvailable = false
    /// Last regular desktop on the menu-bar display. Kept while a full-screen Space is showing.
    private(set) var currentDesktop: SpaceDescriptor?
    private(set) var isOnFullscreenSpace = false
    /// Regular desktops on all displays, Mission Control order.
    private(set) var desktops: [SpaceDescriptor] = []
    private(set) var displayCount = 0
    private(set) var focusProfileID: ProfileID?
    private(set) var focusSource: FocusSource = .none
    /// Resolution for `currentDesktop` (the Dock follows it; wallpapers resolve per display).
    private(set) var resolution: Resolution?
    private(set) var dockActivity: DockActivity = .idle
    private(set) var lastError: String?
    private(set) var lastDockApply: Date?

    private enum Tuning {
        static let launchDelay: Duration = .seconds(3)          // G7: let the Dock & WallpaperAgent come up at login
        static let wakeDelay: Duration = .seconds(2)
        static let topologyDebounce: Duration = .seconds(1)
        static let rulesDebounce: Duration = .milliseconds(250) // coalesce slider/colour-picker drags
        static let sessionReturnDelay: Duration = .seconds(1)
        static let systemDwell = 0.5                            // launch / wake / topology
        static let quickDwell = 0.2                             // focus / rules / manual
        static let minRestartGap: TimeInterval = 3              // launchd ThrottleInterval is 1 s
        static let maxRestartsPerWindow = 6
        static let restartWindow: TimeInterval = 60
        static let mouseWaitLimit: TimeInterval = 10
        static let dockLaunchWaitLimit: TimeInterval = 10
        static let spaceEventSuppression: TimeInterval = 4
        static let inFlightWaitLimit: TimeInterval = 30         // 3 attempts × (6 s respawn + 1.2 s settle) + slack
        /// Apple's Dock fix-ups can land after verify's read 1.2 s into the respawn (review #21);
        /// the settled reading after a restart (successful or failed apply) is taken this late.
        static let lateFixupDelay: Duration = .seconds(4)
        /// Automatic retries of a failed apply whose inputs didn't change (review #5). After the
        /// last one only a user action, or a new target / revision / live Dock, tries again.
        static let failedRetryBackoff: [Duration] = [.seconds(120), .seconds(600), .seconds(1800)]
        /// "Use Now" on the profile that already is the Focus layer changes nothing in the router,
        /// so no reconcile would follow it; this makes sure the retry it asked for still runs.
        static let userRetryFallback: Duration = .seconds(1)
        /// One more wallpaper pass after a pass left writes macOS hadn't confirmed yet.
        static let wallpaperRecheckDelay: Duration = .seconds(3)
    }

    /// Where `lastError` came from, so one channel's success only clears its own message.
    private enum ErrorOrigin { case dock, throttle, wallpaper, restore, other }

    private var store: Store { .shared }
    private var dock: DockService { .shared }
    private var wallpaper: WallpaperService { .shared }
    private var wallpaperSync: WallpaperSync { .shared }
    private let spaceMonitor = SpaceMonitor()

    // Dock pass
    /// Bumped for every new Dock pass; a pass that wakes from a wait with a stale value bails out.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var dockTask: Task<Void, Never>?
    /// True while `DockService.apply` runs. That pass is never cancelled: cancelling would cut its
    /// internal `Task.sleep`s short (respawn poll, 1.2 s settle) and turn one restart into three.
    @ObservationIgnored private var dockApplyInFlight = false
    /// Newest reason that arrived during an in-flight apply; re-checked as soon as it finishes.
    @ObservationIgnored private var pendingDockReason: ReconcileReason?
    /// Restarts at or before this date don't count towards the circuit breaker (Reset Throttle).
    @ObservationIgnored private var throttleResetAt = Date.distantPast
    /// A user action (Retry, Use Now, Capture, Reset Throttle) wants the Dock applied even if the
    /// very same apply failed before. Consumed by the next pass that gets to a decision.
    @ObservationIgnored private var userRetryRequested = false
    /// The backoff timer fired: same effect as a user retry, for one pass.
    @ObservationIgnored private var backoffRetryDue = false
    /// "<profile>|<revision>" of the failure the backoff ladder belongs to, and the next rung.
    @ObservationIgnored private var failureKey: String?
    @ObservationIgnored private var retryStep = 0
    @ObservationIgnored private var lastFailureMessage: String?
    @ObservationIgnored private var lateFixupTask: Task<Void, Never>?
    /// The Original Dock isn't captured yet (the first-run capture failed). Retried on every
    /// reconcile until it succeeds (review #17).
    @ObservationIgnored private var originalDockPending = false
    /// Last seen "Remember manual Dock edits", to catch it being switched off.
    @ObservationIgnored private var rememberEditsWasOn = true

    // Wallpaper
    /// The running wallpaper pass or restore. They never overlap: a new one cancels this one and
    /// starts once it has stopped (between two slots), so no slot is written by two passes at once.
    @ObservationIgnored private var wallpaperTask: Task<Void, Never>?
    /// Restore Original left slots it couldn't reach yet (interrupted, deferred, failed). While
    /// paused, every reconcile and Space change tries them again (reviews #7/#11).
    @ObservationIgnored private var restorePending = false
    @ObservationIgnored private var restoreRunning = false
    /// Notes from the restore that stay true for its re-runs: the Dock's result, and slots that
    /// can never be put back (WallpaperSync forgets those, so a re-run wouldn't mention them again).
    @ObservationIgnored private var restoreDockProblems: [String] = []
    @ObservationIgnored private var restoreLostNotes: [String] = []
    /// Restore's "put back, but not exactly" notes (a live wallpaper back as a still image), also
    /// reported only once by WallpaperSync.
    @ObservationIgnored private var restoreNotes: [String] = []
    /// From sync passes: slots whose earlier picture can never be put back. WallpaperSync reports
    /// each once and forgets the slot, so they stay on screen until the user dismisses them.
    private var wallpaperLostNotes: [String] = []
    /// The last finished pass's failures that later passes retry (not lost ones).
    @ObservationIgnored private var wallpaperFailures: [String] = []
    @ObservationIgnored private var lastWallpaperMessage: String?
    private static let wallpaperRecheckReason = "recheck"

    // Lifecycle
    @ObservationIgnored private var launchReady = false
    @ObservationIgnored private var sessionActive = true
    @ObservationIgnored private var missedWhileInactive: ReconcileReason?
    @ObservationIgnored private var muteConfigChanges = 0
    @ObservationIgnored private var topologySignature = ""
    @ObservationIgnored private var errorOrigin: ErrorOrigin?
    /// Deleted profile whose manual/Shortcuts Focus choice was already handed back (no repeats).
    @ObservationIgnored private var releasedFocusID: ProfileID?
    @ObservationIgnored private var delayed: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        store.load()
        rememberEditsWasOn = store.settings.rememberDockEdits
        store.onConfigChange = { [weak self] in self?.configDidChange() }
        bootstrapIfNeeded()

        spacesAvailable = spaceMonitor.isAvailable
        if spacesAvailable {
            spaceMonitor.onSpaceChange = { [weak self] new, old in self?.spaceDidChange(new, old: old) }
            spaceMonitor.onTopologyChange = { [weak self] snap in self?.topologyDidChange(snap) }
            spaceMonitor.onVisibleSpacesChange = { [weak self] in self?.visibleSpacesDidChange() }
            spaceMonitor.start()
            let snap = spaceMonitor.snapshot()
            refreshDesktops(snap)
            if let cur = snap?.current, !cur.isUserDesktop { isOnFullscreenSpace = true }
        } else {
            Log.engine.error("Space detection unavailable: desktop rules are disabled, Focus and Default still apply")
        }
        topologySignature = makeTopologySignature()

        let router = FocusRouter.shared
        router.onChange = { [weak self] id, source in self?.focusDidChange(id, source) }
        focusProfileID = router.profileID
        focusSource = router.source
        router.start()
        releaseDeletedFocusChoice()     // a choice persisted by an older build may point nowhere

        observeSystem()
        resolution = Resolver.resolve(config: store.config, focusProfileID: focusProfileID,
                                      desktopKey: currentDesktop?.ruleKey)
        Log.engine.notice("started; first reconcile in 3 s (desktop: \(self.currentDesktop?.description ?? "none", privacy: .public))")
        debounce("launch", after: Tuning.launchDelay) { engine in
            engine.launchReady = true
            engine.reconcile(.launch)
        }
    }

    /// G2: on first launch the user's current Dock becomes both the immutable Original and the
    /// Default profile's Dock, and the runtime says "Default is applied", so launching DockShift
    /// never restarts the Dock. Wallpapers are not captured: Default leaves them alone until the
    /// user gives it one, and every slot DockShift changes keeps its own "before" picture
    /// (WallpaperSync), so first launch never rewrites a wallpaper (reviews #1/#3).
    private func bootstrapIfNeeded() {
        // config.json exists but can't be read: the store is paused and won't save it, so a Default
        // made now would only leave an orphan Docks/<id>.plist and overwrite state.json.
        if store.configWarning?.kind == .configUnreadable {
            Log.engine.error("first-run setup skipped: config.json can't be read")
            return
        }
        var createdDefault = false
        if store.isFirstRun || store.defaultProfile == nil {
            Log.engine.notice("first run: creating Default from the current Dock")
            quietly {
                guard store.defaultProfile == nil else { return }
                store.createProfile(name: "Default", isDefault: true)
                createdDefault = true
            }
        }
        originalDockPending = !store.hasOriginal || createdDefault
        captureOriginalDock()
    }

    /// The Original counts as complete only once it holds a Dock (review #17); a new Default gets
    /// the same layout. Retried on every reconcile until it works, but only while DockShift hasn't
    /// written a layout this session: from then on the live Dock isn't the user's own any more.
    /// (A capture or "New Profile" only *names* the live Dock as a profile's — it stays the user's.)
    /// `snapshot`: a capture the user just made, saved as the Original too instead of a second read.
    private func captureOriginalDock(from snapshot: DockSnapshot? = nil) {
        guard originalDockPending, !dockApplyInFlight else { return }
        if !dock.restartLog.isEmpty || lastDockApply != nil {
            originalDockPending = false
            Log.engine.error("original Dock: DockShift applied a profile before it could be read; Restore Original will leave the Dock as it is")
            return
        }
        let captured: DockSnapshot
        if let snapshot {
            captured = snapshot
        } else {
            do { captured = try dock.captureLive() } catch {
                Log.engine.error("original Dock: capture failed, retrying on the next reconcile: \(error.localizedDescription, privacy: .public)")
                report("Couldn't read the current Dock yet (\(error.localizedDescription)). DockShift keeps trying.", .dock)
                return
            }
        }
        originalDockPending = false
        var filledDefault = false
        quietly {
            store.saveOriginal(dock: captured, wallpaper: nil)
            guard let def = store.defaultProfile, !def.hasDock else { return }
            store.setDockSnapshot(captured, for: def.id)
            guard let fresh = store.profile(def.id), fresh.hasDock else { return }
            store.runtime = RuntimeState(appliedDockProfileID: def.id, appliedDockRevision: fresh.dockRevision,
                                         appliedDockIdentity: dock.identity(of: captured),
                                         appliedDockOK: true, appliedAt: Date())
            filledDefault = true
        }
        clearError(.dock)
        Log.engine.notice("original Dock captured\(filledDefault ? " (also Default's Dock)" : "", privacy: .public)")
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didWakeNotification) { engine in
            engine.debounce("wake", after: Tuning.wakeDelay) { $0.reconcile(.wake) }
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleTopologyCheck() }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionDidResign() }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionDidReturn() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor @Sendable (Engine) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    /// Fast user switching: never touch the Dock or wallpaper of a session that isn't on screen.
    private func sessionDidResign() {
        sessionActive = false
        cancelPendingDockWork()
        wallpaperTask?.cancel()
        cancelDelayed("wallpaperRecheck")
        Log.engine.notice("session inactive: holding all changes")
    }

    private func sessionDidReturn() {
        sessionActive = true
        let reason = missedWhileInactive ?? .wake
        missedWhileInactive = nil
        Log.engine.notice("session active again: reconciling (\(reason.rawValue, privacy: .public))")
        debounce("session", after: Tuning.sessionReturnDelay) { $0.reconcile(reason) }
    }

    // MARK: - Inputs

    private func focusDidChange(_ id: ProfileID?, _ source: FocusSource) {
        if focusProfileID != id { focusProfileID = id }
        if focusSource != source { focusSource = source }
        releasedFocusID = nil
        Log.engine.notice("focus layer: \(self.profileName(id), privacy: .public) (\(source.rawValue, privacy: .public))")
        reconcile(.focusChanged)
    }

    private func spaceDidChange(_ new: SpaceDescriptor, old: SpaceDescriptor?) {
        guard new.isUserDesktop else {
            // The Dock is hidden on full-screen Spaces anyway; keep the last desktop as the key and
            // let the return to a desktop reconcile whatever changed meanwhile. Other displays may
            // have switched in the same gesture, so their wallpapers still get a pass.
            if !isOnFullscreenSpace { isOnFullscreenSpace = true }
            Log.engine.info("on \(new.description, privacy: .public): Dock work deferred until a desktop shows")
            visibleSpacesDidChange()
            return
        }
        if currentDesktop != new { currentDesktop = new }
        if isOnFullscreenSpace { isOnFullscreenSpace = false }
        refreshLabel(for: new)
        Log.engine.info("desktop: \(new.description, privacy: .public) (was \(old?.description ?? "none", privacy: .public))")
        reconcile(.desktopChanged)
    }

    /// Review #15: a display without the menu bar switched desktops. Only wallpapers depend on it.
    private func visibleSpacesDidChange() {
        guard started else { return }
        if store.settings.paused {
            retryPendingRestoreIfNeeded()
            return
        }
        guard sessionActive, launchReady else { return }
        Log.engine.info("a display's visible desktop changed: wallpaper pass only")
        runWallpaperSync("visibleSpacesChanged")
    }

    private func topologyDidChange(_ snap: SpacesSnapshot) {
        refreshDesktops(snap)
        scheduleTopologyCheck()
    }

    /// Every Dock restart DockShift performs changes the screens' visible frames and posts
    /// NSApplicationDockDidRestart, both of which look like topology changes. Reconciling on
    /// those would be a feedback loop (critique/spaces2 pitfall), so only a real change of the
    /// connected displays or of the set of desktops counts.
    private func scheduleTopologyCheck() {
        debounce("topology", after: Tuning.topologyDebounce) { engine in
            engine.refreshDesktops()
            let signature = engine.makeTopologySignature()
            guard signature != engine.topologySignature else {
                Log.engine.debug("topology event without a display/desktop change (e.g. our own Dock restart): ignored")
                return
            }
            engine.topologySignature = signature
            engine.reconcile(.topologyChanged)
        }
    }

    private func configDidChange() {
        releaseDeletedFocusChoice()
        noteRememberEditsSetting()
        guard muteConfigChanges == 0 else { return }
        debounce("rules", after: Tuning.rulesDebounce) { $0.reconcile(.rulesChanged) }
    }

    /// Reviews #25/#28: a menu or Shortcuts choice naming a deleted profile would stick until the
    /// next filter edge and keep the active Focus filter's profile out. Hand the layer back (the
    /// router re-reads the filter). A filter's own choice is left alone: the filter keeps
    /// delivering that id until the user picks another profile in System Settings.
    private func releaseDeletedFocusChoice() {
        guard let id = focusProfileID, store.profile(id) == nil,
              focusSource == .manual || focusSource == .shortcuts, releasedFocusID != id else { return }
        releasedFocusID = id
        Log.engine.notice("focus layer: its \(self.focusSource.rawValue, privacy: .public) profile was deleted; handing the layer back to the Focus filter")
        FocusRouter.shared.explicitRequest(profileID: nil, source: .manual)
    }

    /// "Remember manual Dock edits" was switched off. Edits made while it was on were promised to
    /// be kept, so they are saved into their profile once, now — rather than reverted on the next
    /// pass or adopted as nobody's; the setting then governs new edits only. While paused the
    /// live Dock is nobody's (review #20), and edits from before the pause were saved when pausing.
    private func noteRememberEditsSetting() {
        let on = store.settings.rememberDockEdits
        guard rememberEditsWasOn != on else { return }
        rememberEditsWasOn = on     // first: saving re-enters configDidChange
        guard !on, !store.settings.paused else { return }
        saveKeptHandEdits("“Remember manual Dock edits” was turned off", ignoringSetting: true)
    }

    // MARK: - Desktops

    func refreshDesktops() {
        refreshDesktops(spacesAvailable ? spaceMonitor.snapshot() : nil)
    }

    private func refreshDesktops(_ snap: SpacesSnapshot?) {
        guard let snap else {
            if !desktops.isEmpty { desktops = [] }
            if displayCount != 0 { displayCount = 0 }
            return
        }
        let fresh = snap.spaces.filter(\.isUserDesktop)
        if fresh != desktops { desktops = fresh }
        let count = Set(fresh.map(\.displayIdentifier)).count
        if count != displayCount { displayCount = count }

        if let cur = currentDesktop,
           let same = fresh.first(where: { $0.ruleKey == cur.ruleKey && $0.displayIdentifier == cur.displayIdentifier }) {
            if same != cur { currentDesktop = same }          // new label/id after a reorder or Dock restart
        } else if let now = snap.current, now.isUserDesktop, currentDesktop != now {
            currentDesktop = now                              // launch, or our desktop was removed
        }

        // Labels shift when desktops reorder; keep the rules' "last seen" labels current. Skip keys
        // that appear twice (several displays could each report an empty-uuid first desktop).
        let counts = Dictionary(grouping: fresh, by: \.ruleKey).mapValues(\.count)
        for d in fresh where counts[d.ruleKey] == 1 { refreshLabel(for: d) }
    }

    private func refreshLabel(for desktop: SpaceDescriptor) {
        guard let a = store.assignment(forSpaceKey: desktop.ruleKey),
              a.lastSeenLabel != desktop.label || a.displayIdentifier != desktop.displayIdentifier else { return }
        store.refreshAssignmentLabel(spaceKey: desktop.ruleKey, displayIdentifier: desktop.displayIdentifier,
                                     label: desktop.label)
    }

    private func makeTopologySignature() -> String {
        let screens = NSScreen.screens.map(displayKey(of:)).sorted()
        let spaces = desktops.map { "\($0.displayIdentifier)|\($0.ruleKey)" }.sorted()
        return screens.joined(separator: ",") + "#" + spaces.joined(separator: ",")
    }

    private func displayKey(of screen: NSScreen) -> String {
        (wallpaper.displayUUID(of: screen) ?? screen.localizedName).uppercased()
    }

    // MARK: - Public actions

    /// False while config.json can't be read: DockShift runs on empty stand-in rules then, and
    /// resuming would undo the user's setup (put wallpapers back, re-apply Default's Dock).
    var canResume: Bool { store.configWarning?.kind != .configUnreadable }

    func setPaused(_ paused: Bool) {
        if !paused, !canResume {
            Log.engine.error("resume refused: config.json can't be read")
            report("DockShift stays paused because it can't read its settings file. Fix or move config.json, then reopen DockShift.", .other)
            return
        }
        let wasPaused = store.settings.paused
        if paused, !wasPaused {
            // On resume a changed Dock is adopted as nobody's, so edits still owed to a profile
            // are saved now, while it is clear whose they are.
            saveKeptHandEdits("pausing")
            lateFixupTask?.cancel()      // a reading taken while paused could absorb paused-time edits
        }
        if wasPaused != paused { quietly { store.updateSettings { $0.paused = paused } } }
        if paused, !wasPaused {
            wallpaperTask?.cancel()
            cancelDelayed("wallpaperRecheck")
        } else if !paused {
            restorePending = false
            clearError(.restore)
            if wasPaused { adoptLiveDockAfterPause() }
        }
        Log.engine.notice("\(paused ? "paused" : "resumed", privacy: .public)")
        reconcile(.manual)
    }

    /// Review #20: whatever happened to the Dock while paused (hand edits, a Dock reset, Restore
    /// Original) is nobody's profile edit. Adopt it as unowned, so "remember manual edits" can't
    /// bake it into a profile; the next pass applies the rules' layout as usual.
    private func adoptLiveDockAfterPause() {
        guard !dockApplyInFlight, let live = dock.liveIdentity(), live != store.runtime.appliedDockIdentity else { return }
        store.runtime = RuntimeState(appliedDockProfileID: nil, appliedDockRevision: nil, appliedDockIdentity: live,
                                     appliedDockOK: true, appliedAt: Date())
        Log.engine.notice("dock: changed while paused; adopted as unowned (not saved into any profile)")
    }

    /// The menu's "Apply Profile" goes through the Focus router so it shares the Focus layer's
    /// stickiness rules (sticky until the next Focus-filter edge).
    func applyManually(profileID: ProfileID?) {
        Log.engine.notice("manual focus-layer request: \(self.profileName(profileID), privacy: .public)")
        requestUserRetry()
        FocusRouter.shared.explicitRequest(profileID: profileID, source: .manual)
    }

    /// The UI's "Retry" for a failed Dock apply: tries again now, whatever failed before.
    func retryDock() {
        Log.engine.notice("dock: retry requested")
        requestUserRetry()
        reconcile(.manual)
    }

    /// Deletes a profile; a menu/Shortcuts Focus choice pointing at it is handed back to the filter.
    func deleteProfile(_ id: ProfileID) {
        store.deleteProfile(id)
        releaseDeletedFocusChoice()
    }

    func captureCurrentDock(into id: ProfileID) throws {
        guard store.profile(id) != nil else { throw EngineError.profileNotFound }
        guard !dockApplyInFlight else { throw EngineError.dockBusy }   // would capture a half-restarted Dock
        let snapshot = try dock.captureLive()
        captureOriginalDock(from: snapshot)      // still owed: it is the user's own Dock too
        quietly { store.setDockSnapshot(snapshot, for: id) }
        noteCapturedDock(snapshot, into: id)
        Log.engine.notice("captured the live Dock into \(self.profileName(id), privacy: .public)")
        userRetryRequested = true
        reconcile(.rulesChanged)
    }

    func captureCurrentWallpaper(into id: ProfileID) throws {
        guard store.profile(id) != nil else { throw EngineError.profileNotFound }
        guard let screen = Self.mainScreen else { throw EngineError.noScreen }
        guard let current = wallpaper.currentWallpaper(for: screen) else { throw EngineError.wallpaperUnreadable }
        let choice = try store.ingestWallpaper(from: current.url, placement: current.placement,
                                               fillColor: current.fillColor)
        // → onConfigChange → reconcile; WallpaperSync sees the screen already shows it and writes nothing.
        store.setWallpaper(choice, for: id)
        Log.engine.notice("captured the current wallpaper into \(self.profileName(id), privacy: .public)")
    }

    /// The live Dock plus — only when every desktop shows the same picture — that wallpaper. A
    /// profile's wallpaper goes on every desktop it rules, so taking one screen's picture would
    /// rewrite the other desktops and displays; then the profile gets the Dock only, and the note
    /// says so.
    func createProfileFromCurrentSetup(name: String) throws -> CreatedProfile {
        guard !dockApplyInFlight else { throw EngineError.dockBusy }
        // Capture everything before creating anything, so a failure leaves no half-made profile.
        let snapshot = try dock.captureLive()
        let (choice, note) = currentUniformWallpaper()
        captureOriginalDock(from: snapshot)      // still owed: it is the user's own Dock too
        let profile = quietly {
            let p = store.createProfile(name: name, isDefault: false)
            store.setDockSnapshot(snapshot, for: p.id)
            if let choice { store.setWallpaper(choice, for: p.id) }
            return p
        }
        // Review #16: the new profile's layout *is* the live Dock, so it owns the Dock now, whatever
        // the rules resolved a moment ago (paused, throttled or not). Dock edits made from here on
        // belong to it; if another profile still wins, the next pass applies that one (no restart
        // when the layouts are equal).
        store.runtime = RuntimeState(appliedDockProfileID: profile.id,
                                     appliedDockRevision: store.profile(profile.id)?.dockRevision,
                                     appliedDockIdentity: dock.identity(of: snapshot),
                                     appliedDockOK: true, appliedAt: Date())
        Log.engine.notice("created profile \(profile.name, privacy: .public) from the current setup\(choice == nil ? " (Dock only)" : "", privacy: .public)")
        // The user is looking at exactly this setup, so keep showing it: make the new profile the
        // manual choice instead of snapping back to whatever the rules picked a moment ago. The
        // router's onChange runs the reconcile; reconciling here first would restart the Dock back
        // to the old owner.
        applyManually(profileID: profile.id)
        return CreatedProfile(profile: store.profile(profile.id) ?? profile, note: note)
    }

    /// The picture every desktop shows, copied into DockShift's library (from the user's own file
    /// when known, so the profile shows its name), or nil and why not.
    private func currentUniformWallpaper() -> (WallpaperChoice?, String?) {
        let dockOnly = "so this profile only saved the Dock. Choose its wallpaper on its page."
        let snap = spacesAvailable ? spaceMonitor.snapshot() : nil
        if spacesAvailable && snap == nil {
            return (nil, "DockShift couldn't read your desktops just now, \(dockOnly)")
        }
        guard let picture = wallpaperSync.uniformPicture(snapshot: snap), !picture.path.isEmpty else {
            let readable = Self.mainScreen.flatMap { wallpaper.currentWallpaper(for: $0) } != nil
            return (nil, readable
                    ? "Your desktops show different wallpapers, \(dockOnly)"
                    : "Your wallpaper isn't a picture file (e.g. a live, Aerial or dynamic wallpaper), \(dockOnly)")
        }
        var sources = [picture.path]
        if let own = picture.sourcePath, !own.isEmpty, own != picture.path,
           FileManager.default.isReadableFile(atPath: own) {
            sources.insert(own, at: 0)
        }
        var lastError: Error?
        for path in sources {
            do {
                return (try store.ingestWallpaper(from: URL(fileURLWithPath: path), placement: picture.placement,
                                                  fillColor: picture.fillColor), nil)
            } catch {
                lastError = error
                Log.engine.error("new profile: couldn't copy \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return (nil, "DockShift couldn't copy your wallpaper (\(lastError?.localizedDescription ?? "unknown error")), \(dockOnly)")
    }

    /// After a capture the live Dock *is* that profile's layout. Record it as applied when that
    /// profile owns the Dock (so no restart follows) — and also when the live Dock holds unsaved
    /// edits: otherwise "remember manual edits" would copy the very same edits into the profile
    /// that was applied before, silently changing a profile the user didn't pick.
    private func noteCapturedDock(_ snapshot: DockSnapshot, into id: ProfileID) {
        let identity = dock.identity(of: snapshot)
        let rt = store.runtime
        let owner = Resolver.resolveDock(config: store.config, focusProfileID: focusProfileID,
                                         desktopKey: currentDesktop?.ruleKey).profileID
        let liveWasApplied = rt.appliedDockOK && rt.appliedDockIdentity == identity
        guard owner == id || !liveWasApplied else { return }
        store.runtime = RuntimeState(appliedDockProfileID: id, appliedDockRevision: store.profile(id)?.dockRevision,
                                     appliedDockIdentity: identity, appliedDockOK: true, appliedAt: Date())
    }

    /// The exit path (G11): pause, put back the Dock captured on first launch, and put every
    /// wallpaper slot DockShift changed back to the picture it showed before.
    func restoreOriginal() async {
        // Pausing first also saves hand edits still owed to a profile before the Original replaces them.
        setPaused(true)
        Log.engine.notice("restoring the original Dock and wallpapers")

        // Never run two applies at once: wait for a restart that is already under way.
        let deadline = Date().addingTimeInterval(Tuning.inFlightWaitLimit)
        while dockApplyInFlight {
            guard Date() < deadline else {
                report("Couldn't restore: the Dock is still being changed. Try again in a moment.", .restore)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        var problems: [String] = []
        if let original = store.originalDock() {
            setActivity(.applying("Original"))
            lateFixupTask?.cancel()
            dockApplyInFlight = true
            let result = await dock.apply(original, beforeRestart: suppressSpaceEvents())
            // profileID nil: no profile owns this layout, so edits made to it are never "remembered".
            store.runtime = RuntimeState(appliedDockProfileID: nil, appliedDockRevision: nil,
                                         appliedDockIdentity: result.liveIdentity,
                                         appliedDockOK: result.success, appliedAt: Date())
            if result.success {
                lastDockApply = Date()
                setActivity(store.settings.paused ? .paused : .idle)
            } else {
                let msg = result.message ?? "The original Dock couldn't be restored."
                setActivity(.failed(msg))
                problems.append(msg)
            }
            endInFlight()
        } else {
            problems.append("DockShift couldn't read your Dock when it was first launched, so the Dock was left as it is.")
        }

        restoreDockProblems = problems
        restoreLostNotes = []
        restoreNotes = []
        restorePending = true      // until a restore run reaches every slot
        let task = enqueueWallpaperWork { engine in await engine.restoreWallpapers() }
        await task.value
    }

    func resetThrottle() {
        throttleResetAt = Date()
        cancelDelayed("throttle")
        if dockActivity == .throttled { setActivity(.idle) }
        clearError(.throttle)
        Log.engine.notice("throttle reset")
        requestUserRetry()
        reconcile(.manual)
    }

    func profileName(_ id: ProfileID?) -> String {
        guard let id, let p = store.profile(id) else { return "—" }
        return p.isDefault ? "Default" : p.name
    }

    func describe(_ source: RuleSource) -> String {
        switch source {
        case .focus: return "Focus"
        case .desktop(let key):
            if let d = desktops.first(where: { $0.ruleKey == key }) { return d.label }
            return store.assignment(forSpaceKey: key)?.lastSeenLabel ?? "Desktop"
        case .defaultProfile: return "Default"
        case .none: return "Not set"
        }
    }

    // MARK: - Reconcile

    func reconcile(_ reason: ReconcileReason) {
        guard started else { return }
        if originalDockPending, launchReady, sessionActive, !store.settings.paused { captureOriginalDock() }
        let config = store.config
        // Always keep `resolution` current — the menu shows it even while paused.
        let new = Resolver.resolve(config: config, focusProfileID: focusProfileID, desktopKey: currentDesktop?.ruleKey)
        if new != resolution { resolution = new }
        Log.engine.info("reconcile(\(reason.rawValue, privacy: .public)): dock=\(self.describeChannel(new.dock), privacy: .public) wallpaper=\(self.describeChannel(new.wallpaper), privacy: .public)")

        if config.settings.paused {
            cancelPendingDockWork()
            if !dockApplyInFlight { setActivity(.paused) }
            retryPendingRestoreIfNeeded()
            return
        }
        guard sessionActive else {
            if missedWhileInactive == nil { missedWhileInactive = reason }
            return
        }
        // Anything before the delayed launch reconcile is folded into it (it reads the latest state).
        guard launchReady else { return }

        runWallpaperSync(reason.rawValue)
        requestDockPass(reason)
    }

    private func describeChannel(_ c: ChannelResolution) -> String {
        "\(profileName(c.profileID)) via \(describe(c.source))"
    }

    // MARK: - Dock pass

    private func requestDockPass(_ reason: ReconcileReason) {
        if dockApplyInFlight {
            pendingDockReason = longerDwell(pendingDockReason, reason)
            Log.engine.debug("dock: apply in flight; re-checking when it finishes")
            return
        }
        generation += 1
        let gen = generation
        dockTask?.cancel()
        dockTask = Task { [weak self] in await self?.dockPass(reason, generation: gen) }
    }

    /// Cancels a pass that is still waiting (dwell, mouse, rate limit). An in-flight apply is left
    /// alone — see `dockApplyInFlight`.
    private func cancelPendingDockWork() {
        pendingDockReason = nil
        guard !dockApplyInFlight else { return }
        generation += 1
        dockTask?.cancel()
        dockTask = nil
    }

    /// G5's "while desired != applied" loop: anything that changed the desired state during the
    /// restart was parked in `pendingDockReason`; run one more pass against the newest resolution.
    /// After a *failed* apply the parked reason is dropped unless the target or its revision
    /// changed (or the user asked for a retry): replaying it would only fail again (review #5).
    private func endInFlight(failed: (profile: ProfileID, revision: Int)? = nil) {
        dockApplyInFlight = false
        guard let next = pendingDockReason else { return }
        pendingDockReason = nil
        guard !store.settings.paused else { return }
        guard sessionActive else {
            if missedWhileInactive == nil { missedWhileInactive = next }
            return
        }
        if let failed, !userRetryRequested {
            let now = resolution?.dock.profileID
            if now == failed.profile, store.profile(now)?.dockRevision == failed.revision {
                Log.engine.info("dock: apply failed and the target is unchanged; not re-checking (\(next.rawValue, privacy: .public))")
                return
            }
        }
        Log.engine.info("dock: desired state changed during the restart; re-checking (\(next.rawValue, privacy: .public))")
        requestDockPass(next)
    }

    private func isCurrent(_ gen: Int) -> Bool { !Task.isCancelled && gen == generation }

    private func dwell(for reason: ReconcileReason) -> Double {
        switch reason {
        case .desktopChanged: return min(max(store.settings.desktopDockDwell, 0), 10)
        case .launch, .wake, .topologyChanged: return Tuning.systemDwell
        case .focusChanged, .rulesChanged, .manual: return Tuning.quickDwell
        }
    }

    /// Keeps the reason with the longer dwell, so a desktop switch parked behind a restart still settles.
    private func longerDwell(_ old: ReconcileReason?, _ new: ReconcileReason) -> ReconcileReason {
        guard let old else { return new }
        return dwell(for: old) > dwell(for: new) ? old : new
    }

    private func dockPass(_ reason: ReconcileReason, generation gen: Int) async {
        guard let target = resolution?.dock.profileID, let profile = store.profile(target),
              store.dockSnapshot(for: target) != nil else {
            userRetryRequested = false
            backoffRetryDue = false
            setActivity(.idle)
            Log.engine.debug("dock: nothing to apply (\(reason.rawValue, privacy: .public))")
            return
        }
        // Early exits (one ~8 ms `defaults export`) so desktops sharing a layout never even show
        // "Waiting…", and a held failure doesn't trip the circuit breaker's waits.
        let live = dock.liveIdentity()
        if dockAlreadyShows(profile, live: live) { finishSatisfied(profile, "already applied"); return }
        if targetKeepsHandEdits(target, live: live) { finishSatisfied(profile, Self.keptEditsNote); return }
        if holdsFailedApply(profile, live: live) { return }

        // Dwell: a multi-hop swipe must not restart the Dock on every desktop it passes through.
        if reason == .desktopChanged {
            setActivity(.waiting("Waiting for \(currentDesktop?.label ?? "the desktop") to settle"))
        }
        try? await Task.sleep(for: .seconds(dwell(for: reason)))
        guard isCurrent(gen) else { return }
        guard await waitUntilSafeToRestart(gen) else { return }

        // Re-read after the waits. A rule change always arrives with a new generation, but the
        // snapshot is fetched here so the newest revision is what gets written.
        guard let target = resolution?.dock.profileID, let snapshot = store.dockSnapshot(for: target),
              let profile = store.profile(target) else { setActivity(.idle); return }
        let current = dock.liveIdentity()
        if dockAlreadyShows(profile, live: current) { finishSatisfied(profile, "already applied"); return }
        if targetKeepsHandEdits(target, live: current) { finishSatisfied(profile, Self.keptEditsNote); return }
        if holdsFailedApply(profile, live: current) { return }
        rememberManualEdits(live: current, switchingTo: target)
        guard isCurrent(gen) else { return }
        await applyDock(snapshot, profile: profile)
    }

    private static let keptEditsNote = "shows hand edits; they are saved into it when the Dock switches away"

    /// Skip rule: DockShift applied exactly this revision, the apply verified, and nobody touched
    /// the Dock since (live identity unchanged). The identity — not the profile id alone — is the
    /// key, so editing the active profile or hand-editing the Dock both lead to a re-apply.
    private func dockAlreadyShows(_ profile: Profile, live: [String]?) -> Bool {
        let rt = store.runtime
        guard let live else { return false }
        return rt.appliedDockOK && rt.appliedDockProfileID == profile.id
            && rt.appliedDockRevision == profile.dockRevision && rt.appliedDockIdentity == live
    }

    /// The Dock is as the rules want it: nothing is pending, so a stale failure or throttle notice
    /// must not linger (review #18), and a failure's retry schedule is moot.
    private func finishSatisfied(_ profile: Profile, _ why: String) {
        userRetryRequested = false
        backoffRetryDue = false
        resetFailureTracking()
        setActivity(.idle)
        clearError(.dock)
        clearError(.throttle)
        Log.engine.info("dock: \(profile.name, privacy: .public) \(why, privacy: .public), skip")
    }

    /// Review #5: the runtime still describes the failed apply (ok = false). While its profile,
    /// revision and the live Dock are all unchanged, applying again would just fail again — up to
    /// three restarts per attempt — so only the backoff timer or a user action retries it.
    private func holdsFailedApply(_ profile: Profile, live: [String]?) -> Bool {
        let rt = store.runtime
        guard !rt.appliedDockOK, rt.appliedDockProfileID == profile.id, rt.appliedDockRevision == profile.dockRevision,
              let live, rt.appliedDockIdentity == live, !userRetryRequested, !backoffRetryDue else { return false }
        let msg = lastFailureMessage
            ?? "The Dock layout for “\(profileName(profile.id))” couldn't be applied. Choose Retry to try again."
        setActivity(.failed(msg))
        scheduleFailedRetry(for: profile.id, revision: profile.dockRevision)   // e.g. after a relaunch
        Log.engine.info("dock: \(profile.name, privacy: .public) failed and nothing changed since; not retrying automatically")
        return true
    }

    /// Backoff for a failed apply of (profile, revision). A different failure — or one the user
    /// just retried — starts at the bottom rung; otherwise the next rung follows, unless one is
    /// already pending or the ladder is used up.
    private func scheduleFailedRetry(for id: ProfileID, revision: Int, restartLadder: Bool = false) {
        let key = "\(id.uuidString)|\(revision)"
        if failureKey != key || restartLadder {
            failureKey = key
            retryStep = 0
            cancelDelayed("dockRetry")
        }
        guard delayed["dockRetry"] == nil, retryStep < Tuning.failedRetryBackoff.count else { return }
        let delay = Tuning.failedRetryBackoff[retryStep]
        retryStep += 1
        Log.engine.notice("dock: retrying the failed layout in \(delay, privacy: .public)")
        debounce("dockRetry", after: delay) { engine in
            engine.backoffRetryDue = true
            engine.reconcile(.manual)
        }
    }

    private func resetFailureTracking() {
        failureKey = nil
        retryStep = 0
        lastFailureMessage = nil
        cancelDelayed("dockRetry")
    }

    /// A user action counts as "try again now" for a held failure. When the action itself starts
    /// no reconcile (e.g. "Use Now" on the profile already chosen), the fallback does.
    private func requestUserRetry() {
        userRetryRequested = true
        debounce("userRetry", after: Tuning.userRetryFallback) { engine in
            guard engine.userRetryRequested else { return }
            engine.reconcile(.manual)
        }
    }

    /// G6: the profile whose applied layout has been edited by hand since, when "remember manual
    /// edits" covers it. Only when the last apply *verified* and that profile is unchanged since —
    /// otherwise a failed apply or Apple's own Dock fix-ups would get baked into it.
    private func editedDockOwner(live: [String]?, ignoringSetting: Bool = false) -> Profile? {
        let rt = store.runtime
        guard ignoringSetting || store.settings.rememberDockEdits, rt.appliedDockOK,
              let live, let applied = rt.appliedDockIdentity, live != applied,
              let prevID = rt.appliedDockProfileID, let prev = store.profile(prevID), prev.hasDock,
              rt.appliedDockRevision == prev.dockRevision else { return nil }
        return prev
    }

    /// The target itself owns the edited Dock: nothing is switching away, so the edits stay on
    /// screen untouched and are saved only when the Dock really leaves it (review #10: capturing
    /// here would hijack the "arrange the Dock, then click Capture" flow into whichever profile
    /// happens to be showing).
    private func targetKeepsHandEdits(_ target: ProfileID, live: [String]?) -> Bool {
        editedDockOwner(live: live)?.id == target
    }

    /// Before switching away, save hand edits into the profile that owned the Dock.
    private func rememberManualEdits(live: [String]?, switchingTo target: ProfileID) {
        guard let prev = editedDockOwner(live: live), prev.id != target else { return }
        let captured: DockSnapshot
        do { captured = try dock.captureLive() } catch {
            Log.engine.error("dock: couldn't capture manual edits: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Quiet: this is the engine's own bookkeeping, it must not cancel the pass that is running.
        quietly { store.setDockSnapshot(captured, for: prev.id) }
        Log.engine.notice("dock: saved manual Dock edits into \(prev.name, privacy: .public)")
    }

    /// Saves hand edits "remember manual Dock edits" still owes the profile that owns the Dock,
    /// when the Dock is about to stop being that profile's without a switch away: pausing (resume
    /// adopts a changed Dock as nobody's), Restore Original, or the setting being switched off.
    /// The live Dock is that profile's layout afterwards, so nothing is re-applied for it.
    private func saveKeptHandEdits(_ why: String, ignoringSetting: Bool = false) {
        let rt = store.runtime
        guard !dockApplyInFlight, rt.appliedDockOK, rt.appliedDockProfileID != nil else { return }
        let captured: DockSnapshot
        do { captured = try dock.captureLive() } catch {
            Log.engine.error("dock: couldn't read the Dock to save hand edits (\(why, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return
        }
        let live = dock.identity(of: captured)
        guard let owner = editedDockOwner(live: live, ignoringSetting: ignoringSetting) else { return }
        quietly { store.setDockSnapshot(captured, for: owner.id) }
        guard let saved = store.profile(owner.id), saved.dockRevision != owner.dockRevision else {
            Log.engine.error("dock: couldn't save hand edits into \(owner.name, privacy: .public) (\(why, privacy: .public))")
            return
        }
        store.runtime = RuntimeState(appliedDockProfileID: owner.id, appliedDockRevision: saved.dockRevision,
                                     appliedDockIdentity: live, appliedDockOK: true, appliedAt: Date())
        Log.engine.notice("dock: saved manual Dock edits into \(owner.name, privacy: .public) (\(why, privacy: .public))")
    }

    /// Every gate a restart must pass (spaces2 STEP 5). Returns false to abandon this pass; the
    /// next reconcile (desktop change, throttle release, …) starts a fresh one.
    private func waitUntilSafeToRestart(_ gen: Int) async -> Bool {
        if isOnFullscreenSpace {
            setActivity(.waiting("Waiting until a desktop is showing"))
            Log.engine.info("dock: deferred while a full-screen Space is showing")
            return false
        }

        // Never restart under the user's finger: a drag into the Dock, an open menu, a window move.
        if NSEvent.pressedMouseButtons != 0 {
            setActivity(.waiting("Waiting for the mouse button to be released"))
            let deadline = Date().addingTimeInterval(Tuning.mouseWaitLimit)
            while NSEvent.pressedMouseButtons != 0, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard isCurrent(gen) else { return false }
            }
        }

        if let last = dock.restartLog.last {
            let remaining = Tuning.minRestartGap - Date().timeIntervalSince(last)
            if remaining > 0 {
                setActivity(.waiting("Waiting between Dock restarts"))
                try? await Task.sleep(for: .seconds(remaining))
                guard isCurrent(gen) else { return false }
            }
        }

        if let releaseAt = throttleReleaseDate() {
            tripThrottle(until: releaseAt)
            return false
        }

        // Re-check the Space right before the signal: the user may have swiped on during the waits.
        if spacesAvailable, let now = spaceMonitor.snapshot()?.current {
            if !now.isUserDesktop {
                setActivity(.waiting("Waiting until a desktop is showing"))
                return false
            }
            if let desk = currentDesktop, now.ruleKey != desk.ruleKey || now.displayIdentifier != desk.displayIdentifier {
                if let seen = spaceMonitor.current, seen.uuid == now.uuid, seen.displayIdentifier == now.displayIdentifier {
                    // The monitor already settled there without telling us; adopt it (starts a new pass).
                    spaceDidChange(now, old: currentDesktop)
                } else {
                    setActivity(.waiting("Waiting for \(now.label) to settle"))   // its event is on the way
                }
                return false
            }
        }

        // At login the Dock may not be up yet (G7).
        if !Self.dockIsRunning {
            setActivity(.waiting("Waiting for the Dock to start"))
            let deadline = Date().addingTimeInterval(Tuning.dockLaunchWaitLimit)
            while !Self.dockIsRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard isCurrent(gen) else { return false }
            }
        }
        return true
    }

    private func applyDock(_ snapshot: DockSnapshot, profile: Profile) async {
        let name = profileName(profile.id)
        let revision = profile.dockRevision
        let userForced = userRetryRequested
        userRetryRequested = false
        backoffRetryDue = false
        lateFixupTask?.cancel()
        setActivity(.applying(name))
        Log.engine.notice("dock: applying \(name, privacy: .public) (rev \(revision))")

        dockApplyInFlight = true
        let result = await dock.apply(snapshot, beforeRestart: suppressSpaceEvents())
        let applied = RuntimeState(appliedDockProfileID: profile.id, appliedDockRevision: revision,
                                   appliedDockIdentity: result.liveIdentity, appliedDockOK: result.success,
                                   appliedAt: Date())
        store.runtime = applied
        if result.restarted {
            scheduleSettledReread(of: applied, target: result.target.isEmpty ? dock.identity(of: snapshot) : result.target,
                                  removed: result.removed)
        }
        if result.success {
            resetFailureTracking()
            lastDockApply = Date()
            setActivity(store.settings.paused ? .paused : .idle)   // paused while it was restarting
            clearError(.dock)
            clearError(.throttle)
            Log.engine.notice("dock: \(name, privacy: .public) applied (restarted: \(result.restarted), attempts: \(result.attempts))\(result.message.map { " — " + $0 } ?? "", privacy: .public)")
            endInFlight()   // last: it may start the next pass
        } else {
            let msg = result.message ?? "The Dock layout for “\(name)” couldn't be applied."
            lastFailureMessage = msg
            setActivity(.failed(msg))
            report(msg, .dock)
            scheduleFailedRetry(for: profile.id, revision: revision, restartLadder: userForced)
            endInFlight(failed: (profile.id, revision))
        }
    }

    /// The Dock settles for a few seconds after a restart, so the reading the apply recorded may
    /// be early. Re-read once, unless a newer apply, a capture or a pause came first.
    /// - success (review #21): a fix-up tile landing after verify would look like a hand edit on
    ///   the next pass. Taken in only if the layout is still all there in order and nothing the
    ///   apply removed came back (that would be the write being undone).
    /// - failure: the hold on a failed apply compares the live Dock with the recorded reading;
    ///   an early one would let the Dock's own settling end the hold and restart it again.
    private func scheduleSettledReread(of applied: RuntimeState, target: [String], removed: [String]) {
        lateFixupTask?.cancel()
        lateFixupTask = Task { [weak self] in
            try? await Task.sleep(for: Tuning.lateFixupDelay)
            guard let self, !Task.isCancelled else { return }
            self.takeSettledReading(of: applied, target: target, removed: removed)
        }
    }

    private func takeSettledReading(of applied: RuntimeState, target: [String], removed: [String]) {
        let rt = store.runtime
        guard !dockApplyInFlight, !store.settings.paused,
              rt.appliedDockProfileID == applied.appliedDockProfileID, rt.appliedDockRevision == applied.appliedDockRevision,
              rt.appliedAt == applied.appliedAt, rt.appliedDockOK == applied.appliedDockOK,
              rt.appliedDockIdentity == applied.appliedDockIdentity,
              let live = dock.liveIdentity(), live != rt.appliedDockIdentity else { return }
        let before = rt.appliedDockIdentity?.count ?? 0
        if rt.appliedDockOK {
            guard Self.isSubsequence(target, of: live) else {
                Log.engine.info("dock: changed within seconds of the apply and part of the layout is gone; left to the next pass")
                return
            }
            let back = DockService.multisetIntersection(DockService.multisetMinus(live, target), removed)
            guard back.isEmpty else {
                Log.engine.notice("dock: \(back.joined(separator: ", "), privacy: .public) came back within seconds of the apply; not taken as a fix-up")
                return
            }
            Log.engine.notice("dock: took a late Dock fix-up into the applied layout (\(before) → \(live.count) tiles)")
        } else {
            Log.engine.info("dock: the Dock settled after the failed apply (\(before) → \(live.count) tiles); holding on that reading")
        }
        var updated = rt
        updated.appliedDockIdentity = live
        store.runtime = updated
    }

    private static func isSubsequence(_ needle: [String], of haystack: [String]) -> Bool {
        var i = needle.startIndex
        for item in haystack where i < needle.endIndex && item == needle[i] { i += 1 }
        return i == needle.endIndex
    }

    /// Our own restart makes the Space system blink; hold Space events back (deferred, not dropped).
    private func suppressSpaceEvents() -> @MainActor () -> Void {
        let monitor = spaceMonitor
        return { monitor.suppress(for: Tuning.spaceEventSuppression) }
    }

    private static var dockIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").contains { !$0.isTerminated }
    }

    // MARK: - Circuit breaker

    private func recentRestarts(now: Date = Date()) -> [Date] {
        dock.restartLog
            .filter { $0 > throttleResetAt && now.timeIntervalSince($0) < Tuning.restartWindow }
            .sorted()
    }

    /// nil while a whole apply (up to `DockService.maxAttempts` restarts) still fits in the budget
    /// of `maxRestartsPerWindow` per minute (review #5); otherwise the moment enough of the recent
    /// restarts have aged out of the window for one to fit again.
    private func throttleReleaseDate(now: Date = Date()) -> Date? {
        let recent = recentRestarts(now: now)
        let excess = recent.count + DockService.maxAttempts - Tuning.maxRestartsPerWindow
        guard excess > 0, !recent.isEmpty else { return nil }
        return recent[min(excess, recent.count) - 1].addingTimeInterval(Tuning.restartWindow)
    }

    private func tripThrottle(until releaseAt: Date) {
        setActivity(.throttled)
        let seconds = max(1, Int(releaseAt.timeIntervalSinceNow.rounded(.up)))
        let count = recentRestarts().count
        report("The Dock was restarted \(count) times within a minute, so Dock switching is on hold for about \(seconds) s. Choose Reset Throttle to resume now.", .throttle)
        Log.engine.error("dock: circuit breaker tripped; releasing in \(seconds) s")
        // Re-run once the window has passed, so the Dock still ends up where the rules say. Always
        // clear the hold notice and reconcile, even if a skip pass already left .throttled (#18).
        debounce("throttle", after: .seconds(max(0.1, releaseAt.timeIntervalSinceNow + 0.1))) { engine in
            if engine.dockActivity == .throttled { engine.setActivity(.idle) }
            engine.clearError(.throttle)
            Log.engine.notice("dock: circuit breaker released")
            engine.reconcile(.manual)
        }
    }

    // MARK: - Wallpaper

    /// Wallpaper work runs one task at a time: a new pass cancels the running one and starts once
    /// it has stopped (WallpaperSync checks for cancellation between slots and saves each slot's
    /// bookkeeping right after its write, so a cut-short pass leaves consistent state).
    @discardableResult
    private func enqueueWallpaperWork(_ body: @escaping @MainActor @Sendable (Engine) async -> Void) -> Task<Void, Never> {
        let previous = wallpaperTask
        previous?.cancel()
        cancelDelayed("wallpaperRecheck")        // the newer pass checks those slots itself
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await body(self)
        }
        wallpaperTask = task
        return task
    }

    /// Every reconcile runs a full pass: it is cheap, since a slot whose desired picture equals what
    /// DockShift last wrote — or that no rule wants and DockShift never touched — isn't even read.
    private func runWallpaperSync(_ why: String) {
        enqueueWallpaperWork { engine in await engine.syncWallpapers(why) }
    }

    private func syncWallpapers(_ why: String) async {
        let snap = spacesAvailable ? spaceMonitor.snapshot() : nil
        // A nil snapshot means "no Space API": every screen becomes one slot resolved without a
        // desktop rule. With Spaces available that's a transient read failure, and writing the
        // Focus/Default picture would clobber desktop rules: wait for the next pass.
        if spacesAvailable && snap == nil {
            Log.engine.error("wallpaper: Space snapshot unavailable, pass skipped")
            return
        }
        let config = store.config
        let focus = focusProfileID
        let usable = usableWallpapers(in: config)
        let result = await wallpaperSync.sync(snapshot: snap) { ruleKey in
            Self.desiredWallpaper(forDesktop: ruleKey, config: config, focus: focus, usable: usable)
        }
        if result.written > 0 || result.restored > 0 || !result.deferred.isEmpty {
            Log.engine.notice("wallpaper (\(why, privacy: .public)): \(result.written) set, \(result.restored) put back, \(result.deferred.count) waiting until shown")
        }
        for note in result.notes { Log.engine.notice("wallpaper: \(note, privacy: .public)") }
        // Lost put-backs are reported only once, so they are kept even from a cut-short pass.
        let newlyLost = addWallpaperLost(result.lost)
        // Otherwise a cut-short pass says nothing either way: its successor retries every unfinished slot.
        guard !Task.isCancelled else {
            if newlyLost { showWallpaperProblems() }
            return
        }
        wallpaperFailures = result.failed.filter { !result.lost.contains($0) }
        showWallpaperProblems()
        // Writes macOS hadn't confirmed yet may still land: look once more shortly (only once, so
        // a slot that never confirms can't keep passes running; the next event checks it again).
        if wallpaperSync.needsRecheck, why != Self.wallpaperRecheckReason {
            debounce("wallpaperRecheck", after: Tuning.wallpaperRecheckDelay) { engine in
                guard !engine.store.settings.paused, engine.sessionActive, engine.launchReady else { return }
                Log.engine.info("wallpaper: re-checking unconfirmed writes")
                engine.runWallpaperSync(Self.wallpaperRecheckReason)
            }
        }
    }

    @discardableResult
    private func addWallpaperLost(_ items: [String]) -> Bool {
        let new = items.filter { !wallpaperLostNotes.contains($0) }
        if !new.isEmpty { wallpaperLostNotes += new }
        return !new.isEmpty
    }

    /// The wallpaper notice: the last pass's failures (retried by later passes) and put-backs that
    /// can never happen (kept until dismissed). An unchanged notice isn't re-shown over another
    /// channel's newer error.
    private func showWallpaperProblems() {
        var parts: [String] = []
        if !wallpaperFailures.isEmpty {
            parts.append("Couldn't change the wallpaper: \(wallpaperFailures.joined(separator: "; "))")
        }
        if !wallpaperLostNotes.isEmpty {
            parts.append("Can't put the earlier wallpaper back: \(wallpaperLostNotes.joined(separator: "; ")).")
        }
        guard !parts.isEmpty else {
            lastWallpaperMessage = nil
            clearError(.wallpaper)
            return
        }
        let message = parts.joined(separator: "\n")
        guard errorOrigin == nil || errorOrigin == .wallpaper || message != lastWallpaperMessage else { return }
        lastWallpaperMessage = message
        report(message, .wallpaper)
    }

    /// Only a notice that nothing will ever retry — wallpapers that can't be put back — can be
    /// dismissed; it doesn't come back.
    var canDismissError: Bool { errorOrigin == .wallpaper && !wallpaperLostNotes.isEmpty }

    func dismissError() {
        guard canDismissError else { return }
        wallpaperLostNotes = []
        showWallpaperProblems()
    }

    /// Profiles' wallpapers whose managed file is still there. A missing file makes that profile's
    /// choice "nothing wanted" (leave the slot alone / put its picture back), logged once per pass.
    private func usableWallpapers(in config: DockShiftConfig) -> [ProfileID: WallpaperChoice] {
        var usable: [ProfileID: WallpaperChoice] = [:]
        for p in config.profiles {
            guard let choice = p.wallpaper else { continue }
            if store.wallpaperFileExists(choice) {
                usable[p.id] = choice
            } else {
                Log.engine.error("wallpaper: file for \(p.isDefault ? "Default" : p.name, privacy: .public) is missing (\(choice.fileName, privacy: .public))")
            }
        }
        return usable
    }

    /// What one desktop's slots should show. "*" (no Space API) resolves without a desktop layer.
    nonisolated private static func desiredWallpaper(forDesktop ruleKey: String, config: DockShiftConfig,
                                                     focus: ProfileID?, usable: [ProfileID: WallpaperChoice]) -> WallpaperChoice? {
        let res = Resolver.resolveWallpaper(config: config, focusProfileID: focus,
                                            desktopKey: ruleKey == "*" ? nil : ruleKey)
        return res.profileID.flatMap { usable[$0] }
    }

    /// One Restore Original run (re-run while paused for slots it couldn't reach yet). WallpaperSync
    /// forgets a slot that can never be put back (no earlier picture, file gone) and keeps the
    /// others, so a failure whose slot is still recorded is retried later; the rest stays as a note.
    private func restoreWallpapers() async {
        restoreRunning = true
        defer { restoreRunning = false }
        let result = await wallpaperSync.restoreAll(snapshot: spacesAvailable ? spaceMonitor.snapshot() : nil)
        // Resumed meanwhile: the rules own the wallpapers again; only what can never be put back
        // (reported once) is still worth saying.
        guard store.settings.paused else {
            restorePending = false
            if addWallpaperLost(result.lost) { showWallpaperProblems() }
            return
        }
        let interrupted = Task.isCancelled
        // Lost slots are forgotten (reported once, kept here for re-runs); the rest is retried.
        for item in result.lost where !restoreLostNotes.contains(item) { restoreLostNotes.append(item) }
        for note in result.notes where !restoreNotes.contains(note) { restoreNotes.append(note) }
        let retriable = result.failed.filter { !result.lost.contains($0) }
        restorePending = interrupted || !result.deferred.isEmpty || !retriable.isEmpty

        var problems = restoreDockProblems
        if !restoreLostNotes.isEmpty {     // each item already says to pick one in System Settings
            problems.append("Can't be put back: \(restoreLostNotes.joined(separator: "; ")).")
        }
        if !retriable.isEmpty {
            problems.append("Not put back yet: \(retriable.joined(separator: "; ")). DockShift tries again on the next desktop switch.")
        }
        if !result.deferred.isEmpty {
            let one = result.deferred.count == 1
            problems.append("\(result.deferred.joined(separator: ", ")) get\(one ? "s its" : " their") earlier wallpaper back the next time \(one ? "it is" : "they are") on screen — keep DockShift running until then.")
        }
        if interrupted {
            problems.append("Putting the wallpapers back was interrupted; DockShift finishes it on the next desktop switch.")
        }
        Log.engine.notice("restore: \(result.restored) wallpaper(s) put back, \(result.deferred.count) waiting until shown, \(retriable.count) to retry, \(self.restoreLostNotes.count) lost\(interrupted ? ", interrupted" : "", privacy: .public)")
        if problems.isEmpty {
            clearError(.dock)
            clearError(.throttle)
            clearError(.wallpaper)
            clearError(.restore)
            clearError(.other)
            Log.engine.notice("original setup restored")
            // E.g. a live wallpaper that came back as a still image.
            if !restoreNotes.isEmpty { report(restoreNotes.joined(separator: "; ") + ".", .restore) }
        } else {
            report((problems + (restoreNotes.isEmpty ? [] : [restoreNotes.joined(separator: "; ") + "."]))
                   .joined(separator: "\n"), .restore)
        }
    }

    /// Paused after Restore Original with slots left over: try them again (cheap when nothing
    /// changed — hidden desktops stay deferred until they are shown).
    private func retryPendingRestoreIfNeeded() {
        guard restorePending, !restoreRunning, sessionActive, launchReady else { return }
        Log.engine.info("restore: trying the remaining wallpaper slots again")
        enqueueWallpaperWork { engine in
            guard engine.store.settings.paused, engine.restorePending else { return }
            await engine.restoreWallpapers()
        }
    }

    // MARK: - Helpers

    /// The main display (menu bar at login, origin 0,0) — not `NSScreen.main`, which is whichever
    /// screen holds the key window.
    private static var mainScreen: NSScreen? {
        let main = CGMainDisplayID()
        return NSScreen.screens.first { WallpaperService.shared.displayID(of: $0) == main } ?? NSScreen.screens.first
    }

    /// Store mutations made by the engine itself must not bounce back as a `.rulesChanged`
    /// reconcile (which would cancel the pass doing the mutation); callers reconcile explicitly.
    private func quietly<T>(_ body: () throws -> T) rethrows -> T {
        muteConfigChanges += 1
        defer { muteConfigChanges -= 1 }
        return try body()
    }

    private func debounce(_ key: String, after delay: Duration,
                          _ body: @escaping @MainActor @Sendable (Engine) -> Void) {
        delayed[key]?.cancel()
        delayed[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.delayed[key] = nil
            body(self)
        }
    }

    private func cancelDelayed(_ key: String) {
        delayed[key]?.cancel()
        delayed[key] = nil
    }

    private func setActivity(_ activity: DockActivity) {
        if dockActivity != activity { dockActivity = activity }
    }

    private func report(_ message: String, _ origin: ErrorOrigin) {
        Log.engine.error("\(message, privacy: .public)")
        if lastError != message { lastError = message }
        errorOrigin = origin
    }

    /// Clears the error only if it came from the same channel, so a Dock success doesn't hide a
    /// wallpaper failure (and vice versa).
    private func clearError(_ origin: ErrorOrigin) {
        guard lastError != nil, errorOrigin == origin else { return }
        lastError = nil
        errorOrigin = nil
    }
}
