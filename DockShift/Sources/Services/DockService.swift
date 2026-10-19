// DockService.swift — DockShift
// Captures, inspects and applies Dock layouts (`persistent-apps` / `persistent-others` of
// com.apple.dock). The Dock reads its layout only at launch, so applying = write through
// cfprefsd, SIGTERM the Dock (launchd respawns it), then verify with a fresh read and retry.
// Needs a non-sandboxed app: sandboxed CFPreferences writes land in the app's own container.
import AppKit
import Darwin
import UniformTypeIdentifiers
import os

enum DockServiceError: Error, LocalizedError {
    case readFailed(String)
    case managed(String)
    case syncFailed
    case noDockProcess
    case dockDidNotRestart
    /// "-<identity>" missing from the live Dock, "+<identity>" still there although the layout removes it,
    /// "~order" everything is there but in a different order.
    case verifyFailed([String])
    case corruptSnapshot

    var errorDescription: String? {
        switch self {
        case .readFailed(let why):
            return "Couldn't read the Dock settings: \(why)."
        case .managed(let key):
            return "The Dock is managed by a configuration profile (“\(key)” is locked), so DockShift can't change it."
        case .syncFailed:
            return "macOS didn't save the new Dock layout."
        case .noDockProcess:
            return "The Dock isn't running."
        case .dockDidNotRestart:
            return "The Dock didn't come back after restarting it."
        case .verifyFailed(let diff):
            let missing = diff.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }
            let kept = diff.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }
            if !missing.isEmpty { return "The Dock didn't keep the new layout (missing \(dockItemNames(missing)))." }
            if diff.contains("~order") { return "The Dock didn't keep the new layout (items are in a different order)." }
            if !kept.isEmpty { return "The Dock kept \(dockItemNames(kept)), which the new layout removes." }
            return "The Dock didn't keep the new layout."
        case .corruptSnapshot:
            return "The saved Dock layout is damaged. Capture the Dock again."
        }
    }
}

struct DockApplyResult: Sendable {
    var success: Bool
    var restarted: Bool          // false when skipped because the live Dock already matched exactly
    var attempts: Int            // number of write+restart cycles performed (0 if skipped)
    var liveIdentity: [String]   // identity of the live Dock after the operation ([] if unreadable)
    var message: String?         // error / warning text for the UI
    /// Identity of the layout as written (after sanitize: relinked, missing items left out).
    var target: [String] = []
    /// Tiles the apply took out of the Dock (multiset live-before − target). One of them showing up
    /// again later is the write being undone, not a fix-up (the Engine's late re-read checks this).
    var removed: [String] = []
}

@MainActor
final class DockService {
    static let shared = DockService()

    typealias Tile = [String: Any]

    /// Every Dock restart DockShift performed (oldest first, last 50). Feeds the Engine's rate limit.
    private(set) var restartLog: [Date] = []

    static var domain: CFString { "com.apple.dock" as CFString }   // computed: CFString isn't Sendable
    private static let appsKey = "persistent-apps"
    private static let othersKey = "persistent-others"
    private static let dockBundleID = "com.apple.dock"
    private static let dockExecutable = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    /// If MDM forces any of these, user-level layout writes are silently ignored by the Dock.
    private static let managedKeys = [appsKey, othersKey, "static-apps", "static-only", "contents-immutable"]
    /// Write+restart cycles one apply may use (each is a Dock restart).
    nonisolated static let maxAttempts = 3

    private var iconCache: [String: NSImage] = [:]
    private var lastApply: Task<DockApplyResult, Never>?
    private lazy var fallbackIcon: NSImage =
        NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "Missing item")
        ?? NSImage(size: NSSize(width: 32, height: 32))
    private lazy var spacerIcon = NSImage(size: NSSize(width: 32, height: 32))

    private init() {}

    // MARK: - Reading

    /// Reads through a fresh `defaults` process, which sees exactly what cfprefsd (and so a freshly
    /// launched Dock) sees, never a stale in-process CFPreferences cache.
    func captureLive() throws -> DockSnapshot {
        let domain = try Self.readDomain()
        // Absent (not empty) means the Dock hasn't finished its first-login setup: don't capture that.
        guard let apps = Self.tileArray(domain[Self.appsKey]) else {
            throw DockServiceError.readFailed("the Dock hasn't saved a layout yet")
        }
        let others = Self.tileArray(domain[Self.othersKey]) ?? []
        do {
            return DockSnapshot(persistentApps: try Self.encode(apps), persistentOthers: try Self.encode(others),
                                capturedAt: Date(), osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        } catch {
            throw DockServiceError.readFailed(error.localizedDescription)
        }
    }

    /// Semantic identity: "A:"/"O:" + tile-type + "|" + target. After loading tiles the Dock adds
    /// GUID/book/labels, turns POSIX paths into file URLs and resolves Cryptex symlinks, so raw
    /// dictionaries never compare equal across a restart; this does.
    func identity(of snapshot: DockSnapshot) -> [String] {
        guard let apps = Self.decode(snapshot.persistentApps),
              let others = Self.decode(snapshot.persistentOthers) else { return [] }
        return Self.identity(apps: apps, others: others)
    }

    func liveIdentity() -> [String]? { try? readLiveIdentity() }

    func managedKey() -> String? {
        Self.managedKeys.first { CFPreferencesAppValueIsForced($0 as CFString, Self.domain) }
    }

    // MARK: - Applying

    /// Applies are serialized, and run in an unstructured task so a cancelled caller can't turn the
    /// waits into no-ops halfway through a Dock restart (which would cascade into extra restarts).
    func apply(_ snapshot: DockSnapshot, beforeRestart: (@MainActor () -> Void)?) async -> DockApplyResult {
        let previous = lastApply
        let task = Task { @MainActor in
            _ = await previous?.value
            return await self.performApply(snapshot, beforeRestart: beforeRestart)
        }
        lastApply = task
        return await task.value
    }

    private func performApply(_ snapshot: DockSnapshot, beforeRestart: (@MainActor () -> Void)?) async -> DockApplyResult {
        if let key = managedKey() { return failure(DockServiceError.managed(key)) }
        guard let storedApps = Self.decode(snapshot.persistentApps),
              let storedOthers = Self.decode(snapshot.persistentOthers) else {
            return failure(DockServiceError.corruptSnapshot)
        }

        var report = SanitizeReport()
        var guids = Set<Int64>()
        let apps = Self.sanitize(storedApps, guids: &guids, report: &report)
        let others = Self.sanitize(storedOthers, guids: &guids, report: &report)
        for line in report.relinked { Log.dock.info("sanitize: relinked \(line, privacy: .public)") }
        if !report.dropped.isEmpty {
            Log.dock.notice("sanitize: skipping missing \(report.dropped.joined(separator: ", "), privacy: .public)")
        }
        if report.guidsRemoved > 0 { Log.dock.info("sanitize: removed \(report.guidsRemoved) duplicate GUID(s)") }
        let target = Self.identity(apps: apps, others: others)

        let liveTiles: (apps: [Tile], others: [Tile])
        do { liveTiles = try readLiveTiles() } catch { return failure(error) }   // can't verify → don't restart
        let before = Self.identity(apps: liveTiles.apps, others: liveTiles.others)
        if before == target {
            // Same items in the same order, so tiles pair up by position.
            let changed = Self.viewOptionChanges(stored: apps + others, live: liveTiles.apps + liveTiles.others)
            if changed.isEmpty {
                Log.dock.info("apply: live Dock already matches (\(target.count) tiles), no restart")
                return DockApplyResult(success: true, restarted: false, attempts: 0, liveIdentity: before,
                                       message: report.warning, target: target)
            }
            Log.dock.info("apply: same items, different options for \(changed.joined(separator: ", "), privacy: .public)")
        } else {
            Log.dock.info("apply: \(before.count) live tiles → \(target.count) target tiles")
        }

        // Tiles this layout takes out of the Dock. Any of them still there after a restart means the
        // write was undone (e.g. the dying Dock flushing its old list over ours), not a fix-up.
        let removed = Self.multisetMinus(before, target)
        var restarted = false
        var killHard = false
        var live = before
        var diff: [String] = []
        for attempt in 1...Self.maxAttempts {
            do {
                Log.dock.info("apply: attempt \(attempt): writing \(apps.count) apps, \(others.count) others")
                try write(apps: apps, others: others)
                beforeRestart?()
                let oldPIDs = try terminateDock(hard: killHard)
                restarted = true
                try await waitForNewDock(replacing: oldPIDs)
                await pause(.milliseconds(1200))          // let the new Dock load and run its fix-ups
                live = try await readLiveIdentityAfterRestart()
            } catch {
                return failure(error, restarted: restarted, attempts: attempt)
            }

            // Subsequence, not equality: the respawned Dock may insert tiles of its own
            // (DockAutoAddLocation / dockfixup), and retrying would never make those go away.
            if Self.isSubsequence(target, of: live) {
                let extras = Self.multisetMinus(live, target)
                // Apps the Dock re-adds by itself (DockAutoAddLocation) get the benefit of the doubt
                // only after one retry: a single revert must not pass as "macOS added it". Nothing
                // else the layout removed may come back (dockfixup entries included).
                let kept = Self.multisetIntersection(extras, removed)
                let reverted = attempt == 1 ? kept : kept.filter { !Self.isAutoAddedByDock($0) }
                if reverted.isEmpty {
                    var notes = report.warning.map { [$0] } ?? []
                    if !extras.isEmpty {
                        Log.dock.notice("verify: Dock added \(extras.joined(separator: ", "), privacy: .public)")
                        notes.append("macOS added \(dockItemNames(extras)) to the Dock.")
                    }
                    Log.dock.info("apply: verified after \(attempt) attempt(s)")
                    return DockApplyResult(success: true, restarted: true, attempts: attempt, liveIdentity: live,
                                           message: notes.isEmpty ? nil : notes.joined(separator: " "),
                                           target: target, removed: removed)
                }
                diff = reverted.map { "+" + $0 }
                // If the old Dock wrote its list back on the way out, a second SIGTERM would let the
                // respawned one (which loaded that list) do the same; SIGKILL runs no exit path.
                killHard = true
                Log.dock.notice("verify: attempt \(attempt): the Dock kept \(reverted.joined(separator: ", "), privacy: .public), treating as reverted")
                continue
            }
            let missing = Self.multisetMinus(target, live)
            diff = missing.map { "-" + $0 } + Self.multisetMinus(live, target).map { "+" + $0 }
            if missing.isEmpty { diff.append("~order") }
            Log.dock.error("verify: attempt \(attempt) mismatch: \(diff.joined(separator: ", "), privacy: .public)")
        }
        return failure(DockServiceError.verifyFailed(diff), restarted: restarted, attempts: Self.maxAttempts, live: live)
    }

    private func failure(_ error: Error, restarted: Bool = false, attempts: Int = 0, live: [String]? = nil) -> DockApplyResult {
        let message = error.localizedDescription
        Log.dock.error("apply failed: \(message, privacy: .public)")
        return DockApplyResult(success: false, restarted: restarted, attempts: attempts,
                               liveIdentity: live ?? liveIdentity() ?? [], message: message)
    }

    /// Only the two layout keys, per key. Never the whole domain (`defaults import`): that would
    /// rewrite mod-count/loc/region and can trigger the Dock's region fix-up.
    private func write(apps: [Tile], others: [Tile]) throws {
        CFPreferencesSetAppValue(Self.appsKey as CFString, apps as CFArray, Self.domain)
        CFPreferencesSetAppValue(Self.othersKey as CFString, others as CFArray, Self.domain)
        guard CFPreferencesAppSynchronize(Self.domain) else { throw DockServiceError.syncFailed }
    }

    /// SIGTERM, exactly what `killall Dock` does; launchd (KeepAlive SuccessfulExit=false,
    /// ThrottleInterval 1) respawns it, after SIGKILL too. Not `launchctl kickstart -k` (refused for
    /// system agents since 14.4) and not `NSRunningApplication.terminate()` (an Apple Event, i.e. a
    /// possible Automation prompt).
    private func terminateDock(hard: Bool) throws -> Set<pid_t> {
        let pids = Self.dockPIDs()
        guard !pids.isEmpty else { throw DockServiceError.noDockProcess }
        for pid in pids { kill(pid, hard ? SIGKILL : SIGTERM) }
        restartLog.append(Date())
        if restartLog.count > 50 { restartLog.removeFirst(restartLog.count - 50) }
        Log.dock.info("restart: \(hard ? "SIGKILL" : "SIGTERM", privacy: .public) → Dock pid(s) \(pids.map(String.init).joined(separator: ","), privacy: .public)")
        return pids
    }

    private func waitForNewDock(replacing old: Set<pid_t>) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < .seconds(6) {
            await pause(.milliseconds(100))
            if let pid = Self.dockPIDs().first(where: { !old.contains($0) }) {
                Log.dock.info("restart: new Dock pid \(pid) after \(clock.now - start, privacy: .public)")
                return
            }
        }
        throw DockServiceError.dockDidNotRestart
    }

    private func readLiveIdentityAfterRestart() async throws -> [String] {
        var lastError: Error = DockServiceError.readFailed("no attempt")
        for _ in 0..<3 {
            do { return try readLiveIdentity() } catch { lastError = error }
            await pause(.milliseconds(300))
        }
        throw lastError
    }

    private func readLiveIdentity() throws -> [String] {
        let tiles = try readLiveTiles()
        return Self.identity(apps: tiles.apps, others: tiles.others)
    }

    private func readLiveTiles() throws -> (apps: [Tile], others: [Tile]) {
        let domain = try Self.readDomain()
        return (Self.tileArray(domain[Self.appsKey]) ?? [], Self.tileArray(domain[Self.othersKey]) ?? [])
    }

    private func pause(_ duration: Duration) async { try? await Task.sleep(for: duration) }

    // MARK: - Sanitizing

    struct SanitizeReport {
        var relinked: [String] = []
        var dropped: [String] = []
        var guidsRemoved = 0

        var warning: String? {
            dropped.isEmpty ? nil : "Skipped \(dropped.count) missing item(s): \(dropped.joined(separator: ", "))."
        }
    }

    /// Prepares stored tiles for writing. Tiles whose target exists stay byte-for-byte; moved apps
    /// are relinked (bundle id, then bookmark) with the derived fields dropped so the Dock rebuilds
    /// them; unresolvable tiles are left out of the written copy only (the stored profile keeps them,
    /// so they come back once the app is reinstalled). Duplicate GUIDs are removed: the Dock assigns
    /// fresh ones, as it does for its own GUID-less default.plist.
    static func sanitize(_ tiles: [Tile], guids: inout Set<Int64>, report: inout SanitizeReport) -> [Tile] {
        var result: [Tile] = []
        for var tile in tiles {
            let type = tileType(tile)
            if type == "file-tile" || type == "directory-tile" {
                guard let target = resolveTarget(tileData(tile)) else {
                    report.dropped.append(label(of: tile))
                    continue
                }
                if target.relinked {
                    var data = tileData(tile)
                    data["file-data"] = ["_CFURLString": target.url.absoluteString, "_CFURLStringType": 15] as [String: Any]
                    for key in ["book", "file-mod-date", "parent-mod-date", "dock-extra", "home directory relative"] {
                        data.removeValue(forKey: key)
                    }
                    tile["tile-data"] = data
                    report.relinked.append("\(label(of: tile)) → \(target.url.path)")
                }
            }
            if let guid = (tile["GUID"] as? NSNumber)?.int64Value, !guids.insert(guid).inserted {
                tile.removeValue(forKey: "GUID")
                report.guidsRemoved += 1
            }
            result.append(tile)
        }
        return result
    }

    /// Where a file/directory tile points now: its own target while that exists, else a usable copy
    /// of the app with the same bundle id, else its bookmark. nil = missing.
    private static func resolveTarget(_ data: [String: Any]) -> (url: URL, relinked: Bool)? {
        if let url = fileURL(data), url.isFileURL, FileManager.default.fileExists(atPath: url.path) { return (url, false) }
        // Resolve symlinks so e.g. Safari is written as its Cryptex path, not as an alias tile.
        if let bundleID = data["bundle-identifier"] as? String {
            let workspace = NSWorkspace.shared
            // The preferred copy first; every registered copy only when that one is unusable.
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID)?.resolvingSymlinksInPath(),
               isUsableRelink(url) {
                return (url, true)
            }
            if let url = workspace.urlsForApplications(withBundleIdentifier: bundleID).lazy
                .map({ $0.resolvingSymlinksInPath() }).first(where: isUsableRelink) {
                return (url, true)
            }
        }
        if let book = data["book"] as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: book, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let resolved = url.resolvingSymlinksInPath()
                if isUsableRelink(resolved) { return (resolved, true) }
            }
        }
        return nil
    }

    /// A relink candidate worth pinning: it exists, isn't in a Trash (bookmarks follow an app the
    /// user dragged there) and isn't on a read-only volume such as a mounted installer DMG or an
    /// App Translocation mount. Rejected candidates leave the tile missing.
    private static func isUsableRelink(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        if url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) { return false }
        if let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
           url.path.hasPrefix(trash.resolvingSymlinksInPath().standardizedFileURL.path + "/") {
            return false
        }
        // The sealed system volume and the Cryptex volume (Apple's own apps) never count as read-only here.
        let volume = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsRootFileSystemKey])
        if volume?.volumeIsReadOnly == true, volume?.volumeIsRootFileSystem != true, !url.path.hasPrefix("/System/") {
            return false
        }
        return true
    }

    // MARK: - Identity helpers

    static func identity(apps: [Tile], others: [Tile]) -> [String] {
        apps.map { "A:" + tileIdentity($0) } + others.map { "O:" + tileIdentity($0) }
    }

    private static func tileIdentity(_ tile: Tile) -> String {
        let type = tileType(tile)
        let data = tileData(tile)
        if type.hasSuffix("spacer-tile") { return type + "|" }
        if type == "url-tile" { return type + "|" + (urlTileString(data) ?? "") }
        return type + "|" + (fileURL(data).map(normalizedPath) ?? "?")
    }

    /// Absent tile-type means file-tile (Apple's default.plist omits it).
    private static func tileType(_ tile: Tile) -> String { tile["tile-type"] as? String ?? "file-tile" }
    private static func tileData(_ tile: Tile) -> [String: Any] { tile["tile-data"] as? [String: Any] ?? [:] }
    private static func urlTileString(_ data: [String: Any]) -> String? {
        (data["url"] as? [String: Any])?["_CFURLString"] as? String
    }

    /// file-data is CF's URL plist form: _CFURLStringType 0 = POSIX path, 15 = URL string.
    /// Apple's default.plist uses "home directory relative" (e.g. "~/Downloads") instead.
    private static func fileURL(_ data: [String: Any]) -> URL? {
        if let fileData = data["file-data"] as? [String: Any],
           let string = fileData["_CFURLString"] as? String, !string.isEmpty {
            if fileData["_CFURLStringType"] as? Int == 0 { return URL(fileURLWithPath: string) }
            if let url = URL(string: string), url.scheme != nil { return url }
            return URL(fileURLWithPath: string)
        }
        if let relative = data["home directory relative"] as? String, !relative.isEmpty {
            if relative.hasPrefix("/") { return URL(fileURLWithPath: relative) }
            if relative.hasPrefix("~") { return URL(fileURLWithPath: (relative as NSString).expandingTildeInPath) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative)
        }
        return nil
    }

    private static func normalizedPath(_ url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func label(of tile: Tile) -> String {
        let data = tileData(tile)
        return data["file-label"] as? String ?? data["label"] as? String
            ?? fileURL(data)?.deletingPathExtension().lastPathComponent ?? tileType(tile)
    }

    private static func isSubsequence(_ needle: [String], of haystack: [String]) -> Bool {
        var rest = haystack[...]
        for item in needle {
            guard let index = rest.firstIndex(of: item) else { return false }
            rest = rest[rest.index(after: index)...]
        }
        return true
    }

    /// Elements of `a` left over after removing one match from `b` per element (multiset a − b).
    nonisolated static func multisetMinus(_ a: [String], _ b: [String]) -> [String] {
        var counts = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
        return a.filter { item in
            guard let n = counts[item], n > 0 else { return true }
            counts[item] = n - 1
            return false
        }
    }

    /// Elements of `a` that also occur in `b`, one match per element (multiset a ∩ b).
    nonisolated static func multisetIntersection(_ a: [String], _ b: [String]) -> [String] {
        multisetMinus(a, multisetMinus(a, b))
    }

    /// Whether an identity is an app the Dock inserts by itself whenever it is missing, so its
    /// reappearance after a removal may be the Dock's doing rather than a reverted write.
    private static func isAutoAddedByDock(_ identity: String) -> Bool {
        guard let bar = identity.firstIndex(of: "|") else { return false }
        return autoAddTargets.contains(String(identity[identity.index(after: bar)...]))
    }

    /// Identity targets (normalized paths) of the apps in DockAutoAddLocation.plist, the only items
    /// the Dock puts back by itself after a removal. com.apple.dockfixup.plist's add-app / add-doc
    /// entries (Maps, Photos, TV, Downloads…) are one-time OS-upgrade insertions: one that wasn't in
    /// the Dock before the apply is accepted anyway as a plain extra, and one the layout removed
    /// coming back is a reverted write — removing exactly those is a common Focus layout.
    private static let autoAddTargets: Set<String> = {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app/Contents/Resources/DockAutoAddLocation.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return [] }
        var targets = Set<String>()
        for bundleID in plist.keys {
            for app in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID) {
                targets.insert(normalizedPath(app))
            }
        }
        return targets
    }()

    /// Stack view options and link labels aren't part of the identity (the Dock fills in and
    /// normalizes them after launch, so verify can't depend on them), yet a layout that differs only
    /// in them still has to be written. Compares tiles paired by position, and only the keys the
    /// stored tile carries. Returns the labels of the tiles that differ.
    private static func viewOptionChanges(stored: [Tile], live: [Tile]) -> [String] {
        zip(stored, live).compactMap { storedTile, liveTile in
            let keys: [String]
            switch tileType(storedTile) {
            case "directory-tile": keys = ["displayas", "showas", "arrangement", "preferreditemsize"]
            case "url-tile": keys = ["label"]
            default: return nil
            }
            let want = tileData(storedTile), have = tileData(liveTile)
            let differs = keys.contains { key in
                guard let wanted = want[key] as? NSObject else { return false }
                guard let current = have[key] as? NSObject else { return true }
                return !wanted.isEqual(current)
            }
            return differs ? label(of: storedTile) : nil
        }
    }

    // MARK: - Plist plumbing

    private static func decode(_ data: Data) -> [Tile]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return tileArray(plist)
    }

    /// Binary plist keeps NSNumber Bool/Int and Int64 values exactly as the Dock wrote them.
    private static func encode(_ tiles: [Tile]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: tiles, format: .binary, options: 0)
    }

    private static func tileArray(_ value: Any?) -> [Tile]? {
        (value as? [Any])?.compactMap { $0 as? Tile }
    }

    /// `defaults export com.apple.dock -` (~8 ms). Waits through terminationHandler rather than
    /// waitUntilExit(), which spins the main run loop and would let other main-actor work run
    /// re-entrantly inside this synchronous call. A watchdog kills a `defaults` stuck on a stalled
    /// cfprefsd so the app can't freeze.
    private static func readDomain() throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["export", "com.apple.dock", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        let finished = OSAllocatedUnfairLock(initialState: false)
        process.terminationHandler = { _ in
            finished.withLock { $0 = true }
            exited.signal()
        }
        do { try process.run() } catch { throw DockServiceError.readFailed(error.localizedDescription) }

        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            finished.withLock { done in if !done { kill(pid, SIGKILL) } }
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        guard exited.wait(timeout: .now() + 6) == .success else {
            throw DockServiceError.readFailed("defaults export timed out")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw DockServiceError.readFailed("defaults export failed (status \(process.terminationStatus))")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let domain = plist as? [String: Any] else {
            throw DockServiceError.readFailed("defaults export returned unreadable data")
        }
        return domain
    }

    /// Live Dock pids. NSRunningApplication is the documented route; the process-table scan backs it
    /// up in case LaunchServices hasn't caught up with a respawn yet.
    private static func dockPIDs() -> Set<pid_t> {
        var pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier))
        pids.formUnion(processTablePIDs(executable: dockExecutable))
        return pids.filter { $0 > 0 && kill($0, 0) == 0 }
    }

    private static func processTablePIDs(executable: String) -> Set<pid_t> {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        var found = Set<pid_t>()
        for pid in pids.prefix(max(0, min(count, capacity))) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path == executable { found.insert(pid) }
        }
        return found
    }

    // MARK: - Preview

    func tiles(of snapshot: DockSnapshot) -> [DockTileInfo] {
        let apps = Self.decode(snapshot.persistentApps) ?? []
        let others = Self.decode(snapshot.persistentOthers) ?? []
        return apps.enumerated().map { Self.info($1, section: .apps, index: $0) }
            + others.enumerated().map { Self.info($1, section: .others, index: $0) }
    }

    private static func info(_ tile: Tile, section: DockTileInfo.Section, index: Int) -> DockTileInfo {
        let id = "\(section.rawValue)-\(index)"
        let type = tileType(tile)
        let data = tileData(tile)
        switch type {
        case "spacer-tile", "small-spacer-tile", "flex-spacer-tile":
            let kind: DockTileInfo.Kind = type == "spacer-tile" ? .spacer : type == "small-spacer-tile" ? .smallSpacer : .flexSpacer
            return DockTileInfo(id: id, section: section, kind: kind,
                                label: kind == .flexSpacer ? "Flexible Space" : "Space",
                                path: nil, bundleIdentifier: nil, urlString: nil, isMissing: false)
        case "url-tile":
            let string = urlTileString(data)
            let label = data["label"] as? String ?? string.flatMap { URL(string: $0)?.host() } ?? string ?? "Link"
            return DockTileInfo(id: id, section: section, kind: .url, label: label,
                                path: nil, bundleIdentifier: nil, urlString: string, isMissing: false)
        default:
            // Same resolution as sanitize, so the preview shows what an apply would actually write.
            let canGoMissing = type == "file-tile" || type == "directory-tile"
            let target = canGoMissing ? resolveTarget(data) : nil
            let url = target?.url ?? fileURL(data)
            let fileType = data["file-type"] as? Int
            let kind: DockTileInfo.Kind
            switch type {
            case "directory-tile", "smartfolder-tile": kind = .folder
            case "file-tile":
                kind = fileType == 41 || fileType == 169 || url?.pathExtension.lowercased() == "app" ? .app : .file
            default: kind = .other
            }
            return DockTileInfo(id: id, section: section, kind: kind, label: label(of: tile),
                                path: url.map(normalizedPath), bundleIdentifier: data["bundle-identifier"] as? String,
                                urlString: nil, isMissing: canGoMissing && target == nil)
        }
    }

    /// Cached per path / bundle id. Misses aren't cached, so a reinstalled app gets its icon back.
    func icon(for tile: DockTileInfo) -> NSImage {
        let workspace = NSWorkspace.shared
        switch tile.kind {
        case .spacer, .smallSpacer, .flexSpacer:
            return spacerIcon
        case .url:
            return cachedIcon("url:") { workspace.icon(for: .internetLocation) }
        default:
            break
        }
        if let path = tile.path {
            if let image = iconCache["path:" + path] { return image }
            if FileManager.default.fileExists(atPath: path) {
                return cachedIcon("path:" + path) { workspace.icon(forFile: path) }
            }
        }
        if let bundleID = tile.bundleIdentifier {
            if let image = iconCache["bundle:" + bundleID] { return image }
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return cachedIcon("bundle:" + bundleID) { workspace.icon(forFile: url.path) }
            }
        }
        return fallbackIcon
    }

    private func cachedIcon(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = iconCache[key] { return image }
        let image = make()
        iconCache[key] = image
        return image
    }
}

/// "Ghostty, Cursor and 2 more" from identity strings, for UI messages.
private func dockItemNames(_ identities: [String]) -> String {
    let names = identities.map { identity -> String in
        guard let bar = identity.firstIndex(of: "|") else { return identity }
        let target = identity[identity.index(after: bar)...]
        if target.isEmpty { return "a spacer" }
        if target == "?" { return "an unknown item" }
        if target.hasPrefix("/") { return URL(fileURLWithPath: String(target)).deletingPathExtension().lastPathComponent }
        return String(target)
    }
    let shown = names.prefix(3).joined(separator: ", ")
    return names.count > 3 ? "\(shown) and \(names.count - 3) more" : shown
}
