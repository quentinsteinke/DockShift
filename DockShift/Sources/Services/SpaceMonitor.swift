// SpaceMonitor.swift — DockShift
// Detects Space (desktop) switches and identifies the current Space stably.
// Uses private SkyLight/CoreGraphics API resolved with dlsym so a future macOS that drops a
// symbol degrades to "Space features unavailable" instead of failing to launch.
// READ-ONLY: nothing in this file mutates Spaces, the Dock or any preference.
import AppKit
import CoreGraphics

// MARK: - Private API shim

enum CGSSpaces {
    typealias ConnFn = @convention(c) () -> Int32
    typealias CopyArrayFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopyStringFn = @convention(c) (Int32) -> Unmanaged<CFString>?
    typealias DisplayU64Fn = @convention(c) (Int32, CFString) -> UInt64
    typealias DisplayBoolFn = @convention(c) (Int32, CFString) -> Bool
    typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    /// Prefer the SLS* name, fall back to the legacy CGS* alias (both exported on macOS 27.2).
    private static func sym<T>(_ sls: String, _ cgs: String, as: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, sls) ?? dlsym(h, cgs) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static let mainConnectionID = sym("SLSMainConnectionID", "CGSMainConnectionID", as: ConnFn.self)
    static let copyManagedDisplaySpaces = sym("SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces", as: CopyArrayFn.self)
    static let copyActiveMenuBarDisplayIdentifier = sym("SLSCopyActiveMenuBarDisplayIdentifier", "CGSCopyActiveMenuBarDisplayIdentifier", as: CopyStringFn.self)
    static let managedDisplayGetCurrentSpace = sym("SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace", as: DisplayU64Fn.self)
    static let managedDisplayIsAnimating = sym("SLSManagedDisplayIsAnimating", "CGSManagedDisplayIsAnimating", as: DisplayBoolFn.self)
    static let getActiveSpace = sym("SLSGetActiveSpace", "CGSGetActiveSpace", as: ActiveSpaceFn.self)

    static var isAvailable: Bool {
        mainConnectionID != nil && copyManagedDisplaySpaces != nil && copyActiveMenuBarDisplayIdentifier != nil
    }
}

// MARK: - Model

struct SpaceDescriptor: Equatable, Sendable, CustomStringConvertible {
    /// "ManagedSpaceID"/"id64". Session-scoped: reassigned at login and when a display is
    /// reconnected. Use only as a cache key within one run, never persist it.
    let managedID: UInt64
    /// "uuid". Persistent identity of the Space (survives logout/reboot, follows the Space
    /// when it is reordered in Mission Control). "" for the original main desktop.
    let uuid: String
    /// "type": 0 = user desktop, 4 = full-screen app space, 2 = system space.
    let type: Int
    /// "Display Identifier" of the display entry it lives in: a CGDisplay UUID string, or
    /// "Main" when "Displays have separate Spaces" is off.
    let displayIdentifier: String
    /// 1-based position among normal desktops on that display ("Desktop N" in Mission Control).
    let desktopNumber: Int?
    /// pid of the full-screen app (only present on full-screen spaces).
    let fullscreenPID: pid_t?

    var isFullscreen: Bool { type == 4 }
    var isUserDesktop: Bool { type == 0 && !isFullscreen }
    /// Key to persist per-Space rules under. Normalises the main desktop's empty uuid.
    var ruleKey: String { uuid.isEmpty ? SpaceDescriptor.mainDesktopKey : uuid }
    static let mainDesktopKey = "main-desktop"

    var label: String {
        if let n = desktopNumber { return "Desktop \(n)" }
        if isFullscreen, let pid = fullscreenPID,
           let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return "\(name) (Full Screen)" }
        return isFullscreen ? "Full-Screen App" : "Space \(managedID)"
    }
    var description: String { "\(label) [id=\(managedID) uuid=\"\(uuid)\" type=\(type) display=\(displayIdentifier)]" }
}

struct SpacesSnapshot: Sendable {
    let activeDisplayIdentifier: String      // display that owns the menu bar
    let current: SpaceDescriptor?            // current Space on that display
    let currentByDisplay: [String: UInt64]   // every display's current ManagedSpaceID
    let spaces: [SpaceDescriptor]            // all spaces, Mission Control order per display
    let isAnimating: Bool
}

enum SpaceReader {
    static func snapshot() -> SpacesSnapshot? {
        guard CGSSpaces.isAvailable,
              let cid = CGSSpaces.mainConnectionID?(),
              let displays = CGSSpaces.copyManagedDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }

        let menuBarDisplay = CGSSpaces.copyActiveMenuBarDisplayIdentifier?(cid)?.takeRetainedValue() as String?
        return parse(displays, menuBarDisplay: menuBarDisplay) {
            CGSSpaces.managedDisplayIsAnimating?(cid, $0 as CFString) ?? false
        }
    }

    /// Pure parser for the CGSCopyManagedDisplaySpaces payload (unit-testable).
    static func parse(_ displays: [[String: Any]], menuBarDisplay: String?,
                      isAnimating: (String) -> Bool = { _ in false }) -> SpacesSnapshot {
        let identifiers = displays.compactMap { $0["Display Identifier"] as? String }
        // Separate Spaces ON: entries are keyed by display UUID -> pick the menu-bar display.
        // Separate Spaces OFF: a single entry keyed "Main" -> use it.
        let target: String
        if let m = menuBarDisplay, identifiers.contains(m) { target = m }
        else if identifiers.contains("Main") { target = "Main" }
        else { target = identifiers.first ?? "Main" }

        var all: [SpaceDescriptor] = []
        var currentByDisplay: [String: UInt64] = [:]
        var current: SpaceDescriptor?
        for d in displays {
            guard let did = d["Display Identifier"] as? String else { continue }
            let curID = ((d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            if let curID { currentByDisplay[did] = curID }
            var desktopIndex = 0
            for s in (d["Spaces"] as? [[String: Any]]) ?? [] {
                guard let mid = (s["ManagedSpaceID"] as? NSNumber ?? s["id64"] as? NSNumber)?.uint64Value else { continue }
                let type = (s["type"] as? NSNumber)?.intValue ?? 0
                let fullscreen = type == 4 || s["TileLayoutManager"] != nil
                var number: Int?
                if type == 0 && !fullscreen { desktopIndex += 1; number = desktopIndex }
                let desc = SpaceDescriptor(managedID: mid,
                                           uuid: s["uuid"] as? String ?? "",
                                           type: fullscreen ? 4 : type,
                                           displayIdentifier: did,
                                           desktopNumber: number,
                                           fullscreenPID: (s["pid"] as? NSNumber)?.int32Value)
                all.append(desc)
                if did == target, mid == curID { current = desc }
            }
        }
        return SpacesSnapshot(activeDisplayIdentifier: target, current: current,
                              currentByDisplay: currentByDisplay, spaces: all, isAnimating: isAnimating(target))
    }
}

// MARK: - Monitor

@MainActor
final class SpaceMonitor {
    /// Called on the main actor once the user has *settled* on a different Space.
    var onSpaceChange: ((_ new: SpaceDescriptor, _ old: SpaceDescriptor?) -> Void)?
    /// Called when the set/order of Spaces may have changed (UI refresh, orphaned-rule check).
    var onTopologyChange: ((SpacesSnapshot) -> Void)?
    /// Called when another display settled on a different Space while the menu-bar display's
    /// Space stayed the same (separate Spaces: a swipe only changes the display under the pointer).
    var onVisibleSpacesChange: (() -> Void)?

    private(set) var current: SpaceDescriptor?
    /// Every display's current ManagedSpaceID as of the last settled evaluation.
    private(set) var currentByDisplay: [String: UInt64] = [:]
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: DispatchWorkItem?
    private var pendingTopology = false
    private var suppressedUntil = Date.distantPast
    private var lastSample: String?
    private let settleDelay: TimeInterval

    init(settleDelay: TimeInterval = 0.25) { self.settleDelay = settleDelay }

    var isAvailable: Bool { CGSSpaces.isAvailable }

    func start() {
        guard tokens.isEmpty else { return }
        let baseline = SpaceReader.snapshot()                // baseline; do NOT fire on launch
        current = baseline?.current
        currentByDisplay = baseline?.currentByDisplay ?? [:]
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification)                          // primary signal
        observe(ws, Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification"))   // focus moved to another display (undocumented)
        observe(ws, NSWorkspace.didWakeNotification)
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification)                        // fast user switching back
        observe(.default, NSApplication.didChangeScreenParametersNotification, topology: true)
        observe(.default, Notification.Name("NSApplicationDockDidRestartNotification"), topology: true) // exported AppKit const, undocumented
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        pending?.cancel(); pending = nil
    }

    /// Call right before DockShift itself restarts the Dock. Space events that arrive during the
    /// window are re-evaluated once it ends (so a restart can't cause a feedback loop, and a real
    /// swipe made during the restart is still picked up afterwards).
    func suppress(for seconds: TimeInterval) {
        suppressedUntil = max(suppressedUntil, Date().addingTimeInterval(seconds))
    }

    func snapshot() -> SpacesSnapshot? { SpaceReader.snapshot() }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, topology: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(topology: topology) }
        }
        tokens.append((center, token))
    }

    /// Coalesce bursts (multi-hop swipes, MC + display events) and wait for the animation to end.
    private func schedule(topology: Bool, attempt: Int = 0) {
        pending?.cancel()
        pendingTopology = pendingTopology || topology     // don't lose a topology flag when coalescing
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.evaluate(attempt: attempt) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? settleDelay : 0.1), execute: work)
    }

    private func evaluate(attempt: Int) {
        // Our own Dock restart is in flight: don't drop the event, look again once it is over.
        let now = Date()
        if now < suppressedUntil {
            let wait = suppressedUntil.timeIntervalSince(now) + 0.05
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate(attempt: 0) } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        guard let snap = SpaceReader.snapshot() else { return }
        if snap.isAnimating && attempt < 20 { schedule(topology: false, attempt: attempt + 1); return }
        // SLSManagedDisplayIsAnimating is not trusted on recent macOS (yabai), so also require two
        // identical readings 100 ms apart before acting. The other displays' Spaces are part of
        // the sample: a swipe there must settle too.
        let others = snap.currentByDisplay.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let sample = (snap.current.map { "\($0.displayIdentifier)|\($0.uuid)|\($0.managedID)" } ?? "-")
            + "#" + others.joined(separator: ",")
        if sample != lastSample && attempt < 20 {
            lastSample = sample
            schedule(topology: false, attempt: attempt + 1)
            return
        }
        lastSample = nil
        if pendingTopology { pendingTopology = false; onTopologyChange?(snap) }
        let visibleChanged = snap.currentByDisplay != currentByDisplay
        currentByDisplay = snap.currentByDisplay
        guard let new = snap.current else {
            if visibleChanged { onVisibleSpacesChange?() }
            return
        }
        let old = current
        // Compare by persistent identity + display, not ManagedSpaceID.
        if let old, old.uuid == new.uuid, old.displayIdentifier == new.displayIdentifier {
            current = new                      // refresh ids/labels silently (e.g. after reorder)
            if visibleChanged { onVisibleSpacesChange?() }
            return
        }
        current = new
        onSpaceChange?(new, old)              // its reconcile covers every display's wallpaper too
    }
}
