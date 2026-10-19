// FocusRouter.swift — DockShift
// Merges every Focus-layer input into one `(profileID?, FocusSource)` for the Engine:
// Focus-filter pushes, `.current` pulls, the Shortcuts intent and manual menu picks.
// The filter never says WHICH Focus fired, a Work → Personal switch can deliver "off" and "on"
// in either order, and nothing is replayed for transitions that happened while DockShift was
// quit or the Mac slept. So pushes are debounced and confirmed with `.current`, and pulls at
// launch/wake/unlock plus a backstop timer catch what was missed (research/critique.md "Detection").
// Every `.current` read has a deadline, and only one pull runs at a time.
import AppIntents
import AppKit
import Observation

@MainActor @Observable
final class FocusRouter {
    static let shared = FocusRouter()

    private(set) var profileID: ProfileID?
    private(set) var source: FocusSource
    /// Human-readable result of the last `.current` read (shown in the Focus setup UI).
    private(set) var filterStatus = "Not checked yet"
    /// When the Focus filter last pushed a value (proves the filter is wired up).
    private(set) var lastFilterEvent: Date?
    @ObservationIgnored var onChange: (@MainActor (ProfileID?, FocusSource) -> Void)?

    /// What `.current` last reported: a profile uuid, "none" (no filtered Focus is on) or
    /// "notFound" (no Focus uses the filter). Pulls act only when this changes, so the 60 s
    /// timer can't undo a Shortcuts/manual choice. "" = never observed.
    @ObservationIgnored private var lastObservedFilter: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pushGeneration = 0
    /// First push of the latest burst (one Focus switch). Kept after the burst for its recheck.
    @ObservationIgnored private var pushBurstStart = ContinuousClock.now
    @ObservationIgnored private var explicitTask: Task<Void, Never>?
    @ObservationIgnored private var explicitGeneration = 0
    /// When a Shortcuts/menu request for a profile (not a clear) was last committed.
    @ObservationIgnored private var lastExplicitPick: ContinuousClock.Instant?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var eventReason: String?
    @ObservationIgnored private var pullTask: Task<Void, Never>?
    @ObservationIgnored private var queuedPullReason: String?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var launchRetries = 0
    /// `.current` reads that missed their deadline and still haven't answered.
    @ObservationIgnored private var abandonedReads = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var started = false

    private enum Key {
        static let profileID = "focus.profileID"
        static let source = "focus.source"
        static let lastObservedFilter = "focus.lastObservedFilter"
    }

    private enum Observed {
        static let none = "none"
        static let notFound = "notFound"
    }

    /// Long enough for both halves of a Focus → Focus switch to arrive and `.current` to settle.
    private static let pushQuiet: Duration = .milliseconds(1200)
    /// Lets a Shortcuts "on" that follows an "off" (or a double menu click) win without two Dock restarts.
    private static let explicitDelay: Duration = .milliseconds(300)
    /// A Shortcuts automation for the new Focus can fire before the filter's "off" for the old one;
    /// a pick this close before a push burst still belongs to the same switch.
    private static let explicitLead: Duration = .seconds(2)
    private static let eventDelay: Duration = .milliseconds(1500)
    private static let launchDelay: Duration = .seconds(2)
    /// The launch pull is the one level-triggered correction after login: retried if `.current` fails.
    private static let launchRetryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(30)]
    /// Follow-up pull when `.current` contradicts a push (its freshness right after perform() is unverified)
    /// or couldn't be read while clearing an explicit choice.
    private static let recheckDelay: Duration = .seconds(3)
    /// The `.current` XPC has no timeout of its own; a wedged daemon must not stall pushes or pulls.
    private static let readTimeout: Duration = .seconds(3)
    /// Past this many unanswered reads the Focus service is wedged: fail fast instead of adding more.
    private static let maxAbandonedReads = 3
    private static let timerInterval: TimeInterval = 60
    private static let timerTolerance: TimeInterval = 10
    /// Pull reasons that re-sync to `.current` even without an edge (still never over a Shortcuts/manual pick).
    /// "confirm" follows an explicit clear whose `.current` read failed.
    private static let levelTriggeredReasons: Set<String> = ["launch", "manual", "confirm"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedID = defaults.string(forKey: Key.profileID).flatMap(UUID.init(uuidString:))
        let storedSource = defaults.string(forKey: Key.source).flatMap(FocusSource.init(rawValue:)) ?? FocusSource.none
        // A profile without a source (or vice versa) can only come from a damaged file: start clean.
        if let storedID, storedSource != FocusSource.none {
            profileID = storedID
            source = storedSource
        } else {
            profileID = nil
            source = FocusSource.none
        }
        lastObservedFilter = defaults.string(forKey: Key.lastObservedFilter) ?? ""
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didWakeNotification, reason: "wake")
        observe(ws, NSWorkspace.screensDidWakeNotification, reason: "screensWake")
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification, reason: "sessionActive")
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), reason: "unlock")

        // Backstop for anything no notification covers (scheduled Focus edges while locked, missed pushes).
        let timer = Timer(timeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile(reason: "timer") }
        }
        timer.tolerance = Self.timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        scheduleLaunchPull(after: Self.launchDelay)
        Log.focus.info("Focus router started (profile \(Self.describe(self.profileID), privacy: .public), source \(self.source.rawValue, privacy: .public))")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile(reason: reason, after: Self.eventDelay) }
        }
        tokens.append((center, token))
    }

    /// Coalesces bursts (wake + screens wake + unlock arrive together) into one pull, keeping the
    /// strongest pending reason so a wake can't turn a level-triggered confirm into a plain edge check.
    private func scheduleReconcile(reason: String, after delay: Duration) {
        eventTask?.cancel()
        let reason = Self.stronger(eventReason, reason)
        eventReason = reason
        eventTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.eventReason = nil
            self.reconcile(reason: reason)
        }
    }

    /// Own task, not `eventTask`: a wake/unlock pull must not replace the level-triggered launch pull.
    private func scheduleLaunchPull(after delay: Duration) {
        launchTask?.cancel()
        launchTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.reconcile(reason: "launch")
        }
    }

    // MARK: - Inputs

    /// Push from `DockShiftFocusFilter.perform()`. Must return immediately: the work happens
    /// after the Focus switch has gone quiet.
    func filterDelivered(profileID pushed: ProfileID?) {
        lastFilterEvent = Date()
        if pushTask == nil { pushBurstStart = .now }    // first push of this Focus switch
        pushGeneration += 1
        let generation = pushGeneration
        let burstStart = pushBurstStart
        Log.focus.notice("Filter push: \(Self.describe(pushed), privacy: .public)")
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(for: Self.pushQuiet)
            guard !Task.isCancelled, generation == self.pushGeneration else { return }
            let read = await self.readFilter()
            guard !Task.isCancelled, generation == self.pushGeneration else { return }
            self.pushTask = nil
            self.updateStatus(read)

            let id: ProfileID?
            switch read {
            case .active(let current, _):
                id = current
            case .inactive:
                id = nil
            case .notFound, .failed:
                id = pushed     // `.current` is unusable; the push is the only evidence we have
            }
            if read.isReadable, id != pushed {
                Log.focus.warning("Filter push \(Self.describe(pushed), privacy: .public) disagrees with .current \(Self.describe(id), privacy: .public); using .current, re-checking soon")
                self.scheduleReconcile(reason: "recheck", after: Self.recheckDelay)
            }
            // Record what `.current` itself says (not the push), so the next pull compares like
            // with like: a `.current` that keeps answering notFound must not undo every push.
            self.setObserved(read.observedKey ?? Self.observedKey(for: pushed))
            if self.explicitPickWins(over: id, burstStart: burstStart) {
                Log.focus.notice("Filter push \(Self.describe(id), privacy: .public) not applied: the \(self.source.rawValue, privacy: .public) choice \(Self.describe(self.profileID), privacy: .public) belongs to the same Focus switch")
                return
            }
            self.commit(id, id == nil ? .none : .filter, why: "filter push")
        }
    }

    /// Shortcuts intent (`.shortcuts`) or the menu (`.manual`). Sticky until the next filter edge.
    /// nil clears the choice and hands the Focus layer back to the filter.
    func explicitRequest(profileID id: ProfileID?, source requested: FocusSource) {
        explicitGeneration += 1
        let generation = explicitGeneration
        Log.focus.notice("Explicit request (\(requested.rawValue, privacy: .public)): \(Self.describe(id), privacy: .public)")
        explicitTask?.cancel()
        explicitTask = Task { @MainActor in
            try? await Task.sleep(for: Self.explicitDelay)
            guard !Task.isCancelled, generation == self.explicitGeneration else { return }
            if let id {
                self.explicitTask = nil
                self.lastExplicitPick = .now
                self.commit(id, requested, why: "\(requested.rawValue) request")
                return
            }
            // Clearing while a filtered Focus is on should land on that Focus's profile in one
            // transition, not on Default until the next filter edge.
            let read = await self.readFilter()
            guard !Task.isCancelled, generation == self.explicitGeneration else { return }
            self.explicitTask = nil
            self.updateStatus(read)
            let current: ProfileID?
            if case .failed = read {
                // The last thing `.current` reported is the best guess (a filtered Focus may still be
                // on); a level-triggered pull corrects it once `.current` answers again.
                current = UUID(uuidString: self.lastObservedFilter)
                self.scheduleReconcile(reason: "confirm", after: Self.recheckDelay)
            } else {
                if let key = read.observedKey { self.setObserved(key) }
                current = read.profileID
            }
            self.commit(current, current == nil ? .none : .filter, why: "\(requested.rawValue) clear")
        }
    }

    /// Pull `.current` (launch, wake, unlock, timer, "Check Now"). One pull at a time: a timer tick
    /// during a pull is redundant; any other reason runs right after the current one.
    func reconcile(reason: String) {
        guard pullTask == nil else {
            if reason != "timer" { queuedPullReason = Self.stronger(queuedPullReason, reason) }
            Log.focus.debug("Pull (\(reason, privacy: .public)) waits: another pull is running")
            return
        }
        pullTask = Task { @MainActor in
            await self.pull(reason: reason)
            self.pullTask = nil
            if let next = self.queuedPullReason {
                self.queuedPullReason = nil
                self.reconcile(reason: next)
            }
        }
    }

    private func pull(reason: String) async {
        let generation = pushGeneration
        let read = await readFilter()
        updateStatus(read)
        // A push is settling (or arrived during the read): it reads `.current` itself once the
        // switch is over. Acting now could commit an intermediate state and restart the Dock twice.
        guard pushTask == nil, generation == pushGeneration else {
            Log.focus.debug("Pull (\(reason, privacy: .public)) skipped: filter push pending")
            return
        }
        switch read {
        case .active, .inactive:
            let value = read.profileID
            let observed = Self.observedKey(for: value)
            if observed != lastObservedFilter {
                setObserved(observed)
                // The recheck still belongs to the push burst it follows.
                if reason == "recheck", explicitPickWins(over: value, burstStart: pushBurstStart) {
                    Log.focus.notice("Pull (recheck): filter \(Self.describe(value), privacy: .public) not applied over the \(self.source.rawValue, privacy: .public) choice from the same Focus switch")
                    return
                }
                commit(value, value == nil ? .none : .filter, why: "pull (\(reason)): filter changed")
            } else if Self.levelTriggeredReasons.contains(reason), source == .filter || source == .none {
                commit(value, value == nil ? .none : .filter, why: "pull (\(reason))")
            }
        case .notFound:
            // No Focus uses the filter any more: only drop a profile the filter itself chose.
            guard lastObservedFilter != Observed.notFound else { return }
            setObserved(Observed.notFound)
            if source == .filter { commit(nil, .none, why: "pull (\(reason)): filter removed") }
        case .failed(let message):
            Log.focus.error("Pull (\(reason, privacy: .public)) failed: \(message, privacy: .public)")
            if reason == "launch", launchRetries < Self.launchRetryDelays.count {
                let delay = Self.launchRetryDelays[launchRetries]
                launchRetries += 1
                scheduleLaunchPull(after: delay)
            }
        }
    }

    /// A Shortcuts/menu pick from the same Focus switch as a filter push survives it: the filter's
    /// "off" for the old Focus may land before or after the automation for the new one, so a pick
    /// from shortly before the burst beats a nil; a filter "on" yields only to a pick made after the
    /// burst began (an older pick is what that edge is meant to override).
    private func explicitPickWins(over id: ProfileID?, burstStart: ContinuousClock.Instant) -> Bool {
        guard source == .shortcuts || source == .manual, let pick = lastExplicitPick else { return false }
        return id == nil ? pick >= burstStart - Self.explicitLead : pick > burstStart
    }

    // MARK: - State

    private func commit(_ id: ProfileID?, _ requestedSource: FocusSource, why: String) {
        // Keep the invariant "no profile ⇔ source .none".
        let newID = requestedSource == .none ? nil : id
        let newSource = newID == nil ? FocusSource.none : requestedSource
        guard newID != profileID || newSource != source else { return }
        let old = "\(Self.describe(profileID)) (\(source.rawValue))"
        profileID = newID
        source = newSource
        defaults.set(newID?.uuidString, forKey: Key.profileID)
        defaults.set(newSource.rawValue, forKey: Key.source)
        Log.focus.notice("Focus layer: \(old, privacy: .public) → \(Self.describe(newID), privacy: .public) (\(newSource.rawValue, privacy: .public)) — \(why, privacy: .public)")
        onChange?(newID, newSource)
    }

    private func setObserved(_ key: String) {
        guard key != lastObservedFilter else { return }
        lastObservedFilter = key
        defaults.set(key, forKey: Key.lastObservedFilter)
    }

    private func updateStatus(_ read: FilterRead) {
        let text: String
        switch read {
        case .active(_, let name): text = "Focus filter: \(name)"
        case .inactive: text = "No Focus with a DockShift filter is on"
        case .notFound: text = "No Focus uses the DockShift filter yet"
        case .failed(let message): text = "Couldn't read the Focus filter: \(message)"
        }
        if filterStatus != text { filterStatus = text }   // the timer re-reads every minute
    }

    /// Coalescing keeps the reason that does the most: level-triggered > recheck > plain edge check.
    private static func stronger(_ pending: String?, _ new: String) -> String {
        guard let pending else { return new }
        func rank(_ reason: String) -> Int {
            levelTriggeredReasons.contains(reason) ? 2 : reason == "recheck" ? 1 : 0
        }
        return rank(pending) > rank(new) ? pending : new
    }

    // MARK: - Reading the filter

    private enum FilterRead: Sendable {
        case active(ProfileID, String)   // a Focus with the filter is on: profile id + name
        case inactive                    // the filter is configured, but no such Focus is on
        case notFound                    // no Focus uses the filter
        case failed(String)

        var isReadable: Bool {
            switch self {
            case .active, .inactive: return true
            case .notFound, .failed: return false
            }
        }

        var profileID: ProfileID? {
            if case .active(let id, _) = self { return id }
            return nil
        }

        /// Value for `lastObservedFilter`; nil when the read says nothing about the filter.
        var observedKey: String? {
            switch self {
            case .active(let id, _): return id.uuidString
            case .inactive: return Observed.none
            case .notFound: return Observed.notFound
            case .failed: return nil
            }
        }
    }

    /// `.current` with a deadline. The XPC can't be cancelled, so a read that misses it is abandoned
    /// (its late answer ignored); `.failed` then lets a push fall back to the pushed value.
    private func readFilter() async -> FilterRead {
        guard abandonedReads < Self.maxAbandonedReads else {
            return .failed("the Focus service isn't responding")
        }
        return await withCheckedContinuation { continuation in
            let result = FirstResult(continuation)
            let deadline = Task { @MainActor in
                guard (try? await Task.sleep(for: Self.readTimeout)) != nil else { return }
                if result.deliver(.failed("no answer within \(Self.readTimeout.components.seconds) s")) {
                    self.abandonedReads += 1
                }
            }
            Task { @MainActor in
                let read = await Self.readCurrent()
                deadline.cancel()
                if !result.deliver(read) { self.abandonedReads -= 1 }   // answered after the deadline
            }
        }
    }

    /// Off the main actor: only the Sendable result crosses back.
    nonisolated private static func readCurrent() async -> FilterRead {
        do {
            let current = try await DockShiftFocusFilter.current
            guard let profile = current.profile else { return .inactive }
            return .active(profile.id, profile.name)
        } catch SetFocusFilterIntentError.notFound {
            return .notFound
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func observedKey(for id: ProfileID?) -> String {
        id?.uuidString ?? Observed.none
    }

    private static func describe(_ id: ProfileID?) -> String {
        id?.uuidString ?? "none"
    }
}

/// Resumes a continuation with whichever result arrives first; both racers run on the main actor.
@MainActor
private final class FirstResult<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// false when a result was already delivered.
    func deliver(_ value: Value) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}
