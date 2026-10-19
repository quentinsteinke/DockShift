// WallpaperSync.swift — DockShift
// Makes every wallpaper slot (display × desktop) show what the rules want, and puts back what a
// slot showed before once no rule wants it any more. What DockShift did to each slot is persisted
// (Store.wallpaperSlots), so after a relaunch it still knows which pictures are its own and what
// they replaced. A slot is only written when the wanted picture changes: one the user sets in
// System Settings afterwards sticks until then.
import AppKit

struct WallpaperSyncReport: Sendable {
    var written = 0
    var restored = 0
    /// Labels of slots that can only be written while visible (no per-Space API); they update when visited.
    var deferred: [String] = []
    /// "<slot label>: <reason>" for failed or unconfirmed writes and slots that couldn't be reached.
    var failed: [String] = []
    /// The part of `failed` that is reported only once: put-backs that can never happen (DockShift
    /// couldn't tell what was there, or that picture is gone). Their records are forgotten, so a
    /// later pass is clean although the slot still shows DockShift's picture.
    var lost: [String] = []
    /// "<slot label>: <note>" for slots put back with something other than exactly what they
    /// showed, e.g. a live wallpaper that came back as a still image.
    var notes: [String] = []
}

@MainActor
final class WallpaperSync {
    static let shared = WallpaperSync()
    private init() {}

    private var store: Store { .shared }
    private var service: WallpaperService { .shared }

    /// True after a sync pass that left a write unconfirmed (macOS may still apply it): one more
    /// pass ~3 s later confirms it and clears the error, or writes it again. A slot that was already
    /// unconfirmed before the pass doesn't ask again, so re-checks can't chain.
    private(set) var needsRecheck = false

    /// One pass at a time: a cancelled pass still finishes the write it has issued, and the next
    /// pass must not touch that slot meanwhile.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let liveNote = "was a live wallpaper; put back as a still image of macOS's default wallpaper"
    private static let unknownNote = "DockShift couldn't tell what was there before"

    private struct Slot {
        let key: String
        let ruleKey: String
        let displayID: CGDirectDisplayID
        /// "" = Desktop 1; nil = the visible Space of `screen` with unknown identity (no Space API).
        let spaceUUID: String?
        /// ManagedSpaceID, to check that NSWorkspace still sees this Space; nil without the Space API.
        let spaceID: UInt64?
        let screen: NSScreen
        let isVisible: Bool
        let label: String
    }

    // MARK: - Passes

    /// One full pass. `desired(ruleKey)` returns the wanted choice for a desktop (nil = leave
    /// alone/restore). Without the Space API (`snapshot` nil) each screen's visible desktop is one
    /// slot with ruleKey "*". Cancelling stops between slots; each slot's record is saved right
    /// after its write, so a cancelled pass leaves consistent state.
    func sync(snapshot: SpacesSnapshot?, desired: (String) -> WallpaperChoice?) async -> WallpaperSyncReport {
        await lock()
        defer { unlock() }
        needsRecheck = false
        var report = WallpaperSyncReport()
        guard !Task.isCancelled, let slots = slots(in: snapshot) else { return report }
        if snapshot != nil { prune(keeping: slots) }
        var wanted: [String: WallpaperChoice?] = [:]
        for slot in slots {
            guard !Task.isCancelled else { break }
            let want: WallpaperChoice?
            if let cached = wanted[slot.ruleKey] {
                want = cached
            } else {
                want = desired(slot.ruleKey).flatMap { store.wallpaperFileExists($0) ? $0 : nil }
                wanted[slot.ruleKey] = want
            }
            let entry = store.wallpaperSlots[slot.key]
            if let want {
                await apply(want, to: slot, entry: entry, report: &report)
            } else if let entry {
                await putBack(entry, on: slot, report: &report)
            }
        }
        if report.written + report.restored > 0 || !report.failed.isEmpty {
            Log.wallpaper.notice("Pass: \(report.written) written, \(report.restored) put back, \(report.deferred.count) deferred, \(report.failed.count) failed\(self.needsRecheck ? " (re-check wanted)" : "", privacy: .public)")
        }
        return report
    }

    /// Put every changed slot back to what it showed before DockShift and forget it (Restore
    /// Original). Slots the user has changed since are only forgotten. Entries of displays that
    /// aren't connected are kept and reported, so a later restore can still reach them.
    func restoreAll(snapshot: SpacesSnapshot?) async -> WallpaperSyncReport {
        await lock()
        defer { unlock() }
        var report = WallpaperSyncReport()
        let slots = slots(in: snapshot)
        if let slots, snapshot != nil { prune(keeping: slots) }
        for slot in slots ?? [] {
            guard !Task.isCancelled else { return report }
            guard let entry = store.wallpaperSlots[slot.key] else { continue }
            await putBack(entry, on: slot, report: &report)
        }
        let reached = Set((slots ?? []).map(\.key))
        let connected = Set(NSScreen.screens.map(displayKey(of:)))
        for (key, entry) in store.wallpaperSlots.sorted(by: { $0.key < $1.key })
        where !reached.contains(key) && hasPictureToPutBack(entry) {
            let reason = slots == nil ? "DockShift couldn't read your desktops"
                : connected.contains(Self.displayPart(of: key)) ? "DockShift couldn't find that desktop"
                : "its display isn't connected"
            report.failed.append("\(entry.label): \(reason)")
        }
        Log.wallpaper.notice("Restore: \(report.restored) put back, \(report.deferred.count) deferred, \(report.failed.count) not reached")
        return report
    }

    /// The picture every user-desktop slot shows, if they all show the same one (by `shows`); nil
    /// otherwise (different pictures, a placeholder, or unreadable). With no Space API: the main
    /// screen's picture. `path` is the file macOS shows (the user's own); `sourcePath` is nil.
    func uniformPicture(snapshot: SpacesSnapshot?) -> SlotPicture? {
        let readings: [SlotPicture?]
        if snapshot == nil, !CGSSpaces.isAvailable {
            let screens = NSScreen.screens
            guard let screen = screens.first(where: { service.displayID(of: $0) == CGMainDisplayID() }) ?? screens.first,
                  let id = service.displayID(of: screen) else { return nil }
            readings = [service.readSlot(displayID: id, spaceUUID: nil, screen: screen, isVisible: true)]
        } else {
            guard let slots = slots(in: snapshot) else { return nil }
            readings = slots.map(read)
        }
        guard let first = readings.first ?? nil, !isLive(first), service.isImageFile(URL(fileURLWithPath: first.path)),
              readings.dropFirst().allSatisfy({ $0.map { service.shows($0, first) } ?? false })
        else { return nil }
        return first
    }

    // MARK: - Per slot

    private func apply(_ want: WallpaperChoice, to slot: Slot, entry: WallpaperSlot?,
                       report: inout WallpaperSyncReport) async {
        if let entry, entry.applied == want, entry.confirmed {
            // DockShift's write stands — or the user picked something else since, which sticks.
            relabel(entry, on: slot)
            return
        }
        guard reachable(slot) else {
            report.deferred.append(slot.label)
            return
        }
        let target = picture(of: want)
        let current = read(slot)
        // Already right (e.g. the user's own copy of the picture, or a write that landed late).
        // Recorded like a write, so a later manual change sticks here too; without a record the
        // slot showed it before. A live wallpaper is never taken for its still image.
        if let current, !isLive(current), service.shows(current, target) {
            if let entry, entry.applied == want, !entry.confirmed {
                Log.wallpaper.notice("\(slot.label, privacy: .public): \(want.displayName, privacy: .public) landed late")
            }
            var record = entry ?? WallpaperSlot(applied: want, baseline: adopted(current, want), label: slot.label)
            record.applied = want
            record.label = slot.label
            record.confirmed = true
            store.setWallpaperSlot(record, forKey: slot.key)
            return
        }
        // The baseline is what the slot shows now — unless that is DockShift's own picture, can't be
        // read, or may be either (an unconfirmed write): then the recorded one still holds.
        let baseline: SlotPicture?
        let note: String?
        if let entry, !entry.confirmed || current.map({ service.shows($0, picture(of: entry.applied)) }) ?? true {
            (baseline, note) = (entry.baseline, entry.note)
        } else {
            (baseline, note) = capture(current)
        }
        var record = WallpaperSlot(applied: want, baseline: baseline, label: slot.label, note: note)
        switch await write(target, to: slot) {
        case .written:
            store.setWallpaperSlot(record, forKey: slot.key)
            report.written += 1
            Log.wallpaper.notice("\(slot.label, privacy: .public) → \(want.displayName, privacy: .public)")
        case .unconfirmed:
            // It may still land: recorded as DockShift's (with what it replaces) until a pass sees it.
            record.confirmed = false
            store.setWallpaperSlot(record, forKey: slot.key)
            if entry?.confirmed != false { needsRecheck = true }
            report.failed.append("\(slot.label): macOS hasn't confirmed the new wallpaper yet")
        case .deferred:
            report.deferred.append(slot.label)
        case .failed(let reason):
            report.failed.append("\(slot.label): \(reason)")
        }
    }

    /// No rule wants the slot any more (or Restore Original): put back what it showed before
    /// DockShift unless the user has changed it since, then forget it. A put-back that can't happen
    /// yet keeps the record, so a later pass retries it; one that never can is reported and forgotten.
    private func putBack(_ entry: WallpaperSlot, on slot: Slot, report: inout WallpaperSyncReport) async {
        guard reachable(slot) else {
            relabel(entry, on: slot)
            report.deferred.append(slot.label)
            return
        }
        let current = read(slot)
        // Unreadable counts as still ours, and so does a slot whose last write wasn't confirmed (it
        // may show either picture).
        guard !entry.confirmed || current.map({ service.shows($0, picture(of: entry.applied)) }) ?? true else {
            Log.wallpaper.notice("\(slot.label, privacy: .public) was changed since DockShift set it; leaving it")
            forget(slot)
            return
        }
        guard let baseline = entry.baseline else {
            lose(slot, entry.note ?? Self.unknownNote, report: &report)
            return
        }
        guard let source = restorable(baseline) else {
            Log.wallpaper.error("\(slot.label, privacy: .public): the picture it had before is gone (\(baseline.sourcePath ?? baseline.path, privacy: .public))")
            lose(slot, "the picture it had before no longer exists", report: &report)
            return
        }
        // Already back: an unconfirmed put-back that landed late, or the live wallpaper the still
        // stands in for (macOS may show the default Aerial for its still).
        if let current, service.shows(current, source) || (isLive(current) && isLive(source)) {
            forget(slot)
            return
        }
        switch await write(source, to: slot) {
        case .written:
            forget(slot)
            report.restored += 1
            if let note = entry.note { report.notes.append("\(slot.label): \(note)") }
            Log.wallpaper.notice("\(slot.label, privacy: .public) → put back \(URL(fileURLWithPath: source.path).lastPathComponent, privacy: .public)")
        case .unconfirmed:
            var pending = entry
            pending.label = slot.label
            pending.confirmed = false
            store.setWallpaperSlot(pending, forKey: slot.key)
            if entry.confirmed { needsRecheck = true }
            report.failed.append("\(slot.label): macOS hasn't confirmed the wallpaper being put back yet")
        case .deferred:
            relabel(entry, on: slot)
            report.deferred.append(slot.label)
        case .failed(let reason):
            relabel(entry, on: slot)
            report.failed.append("\(slot.label): \(reason)")
        }
    }

    /// Reported (once) and forgotten: the slot keeps DockShift's picture and nothing can put it back.
    private func lose(_ slot: Slot, _ why: String, report: inout WallpaperSyncReport) {
        let item = "\(slot.label): \(why) — pick a wallpaper in System Settings"
        Log.wallpaper.error("\(item, privacy: .public)")
        report.failed.append(item)
        report.lost.append(item)
        forget(slot)
    }

    /// What to put back later, from what the slot showed before DockShift's write:
    /// - an image file: DockShift's copy (survives the user moving or deleting theirs), with their
    ///   file as `sourcePath`; if it can't be copied (e.g. a folder DockShift may not read), the path.
    /// - a live/Aerial wallpaper (no image file): a still image of the default wallpaper, noted.
    /// - unreadable: nothing, noted; put-back then reports the slot instead of guessing.
    private func capture(_ current: SlotPicture?) -> (SlotPicture?, String?) {
        guard let current else { return (nil, Self.unknownNote) }
        if isLive(current) {
            guard let still = service.stillImage(standingInFor: current.path) else {
                return (nil, "it had a live wallpaper DockShift can't put back")
            }
            Log.wallpaper.notice("Live wallpaper; its still image \(still.lastPathComponent, privacy: .public) will be put back")
            return (SlotPicture(path: still.path, placement: .fill, fillColor: current.fillColor), Self.liveNote)
        }
        let url = URL(fileURLWithPath: current.path)
        guard service.isImageFile(url) else {
            return (nil, "DockShift couldn't read the picture it had before (\(url.lastPathComponent))")
        }
        if current.path.hasPrefix("/System/") { return (current, nil) }     // read-only system volume
        do {
            let copy = try store.ingestWallpaper(from: url, placement: current.placement, fillColor: current.fillColor)
            let copyPath = store.fileURL(for: copy).standardizedFileURL.path
            return (SlotPicture(path: copyPath, placement: current.placement, fillColor: current.fillColor,
                                sourcePath: copyPath == url.standardizedFileURL.path ? nil : current.path), nil)
        } catch {
            Log.wallpaper.error("Couldn't copy \(url.lastPathComponent, privacy: .public) (\(error.localizedDescription, privacy: .public)); keeping its path")
            return (current, nil)
        }
    }

    /// The baseline of a slot that already showed the wanted picture: what it showed — the user's
    /// own file as `sourcePath`, its placement and colour — with `want`'s file (the same bytes) as
    /// the copy.
    private func adopted(_ current: SlotPicture, _ want: WallpaperChoice) -> SlotPicture {
        let copy = picture(of: want).path
        let shown = URL(fileURLWithPath: current.path).standardizedFileURL.path
        return SlotPicture(path: copy, placement: current.placement, fillColor: current.fillColor,
                           sourcePath: shown == copy ? nil : current.path)
    }

    /// The file to put back: the user's own while it is still the picture DockShift copied, else
    /// DockShift's copy, else — the copy gone — the user's file as it is now. nil when neither exists.
    private func restorable(_ baseline: SlotPicture) -> SlotPicture? {
        let copyExists = Self.isFile(baseline.path)
        var picture = baseline
        picture.sourcePath = nil
        if let source = baseline.sourcePath, Self.isFile(source),
           !copyExists || service.isUnchanged(source: source, copy: baseline.path) {
            picture.path = source
            return picture
        }
        return copyExists ? picture : nil
    }

    // MARK: - Slots

    /// Every user desktop on every connected screen ("Main" = shared Spaces: every screen × every
    /// desktop), visible ones first. nil when there is no Space reading although the Space API
    /// exists: a transient failure, and guessing would clobber desktop rules.
    private func slots(in snapshot: SpacesSnapshot?) -> [Slot]? {
        let screens = NSScreen.screens
        func label(_ name: String, _ screen: NSScreen) -> String {
            screens.count > 1 ? "\(name) · \(screen.localizedName)" : name
        }
        guard let snapshot else {
            if CGSSpaces.isAvailable {
                Log.wallpaper.error("No Space reading; wallpaper slots unknown")
                return nil
            }
            return screens.compactMap { screen in
                guard let id = service.displayID(of: screen) else { return nil }
                return Slot(key: slotKey(screen, "*"), ruleKey: "*", displayID: id, spaceUUID: nil, spaceID: nil,
                            screen: screen, isVisible: true, label: label("Current desktop", screen))
            }
        }
        let identifiers = Set(snapshot.spaces.map(\.displayIdentifier))
        var visible: [Slot] = []
        var hidden: [Slot] = []
        for screen in screens {
            guard let id = service.displayID(of: screen) else { continue }
            let uuid = service.displayUUID(of: screen)
            guard let display = identifiers.contains("Main") ? "Main"
                    : identifiers.first(where: { uuid?.caseInsensitiveCompare($0) == .orderedSame }) else { continue }
            let current = snapshot.currentByDisplay[display]
            for space in snapshot.spaces where space.displayIdentifier == display && space.isUserDesktop {
                let slot = Slot(key: slotKey(screen, space.ruleKey), ruleKey: space.ruleKey, displayID: id,
                                spaceUUID: space.uuid, spaceID: space.managedID, screen: screen,
                                isVisible: space.managedID == current, label: label(space.label, screen))
                if slot.isVisible { visible.append(slot) } else { hidden.append(slot) }
            }
        }
        return visible + hidden
    }

    /// Forgets slots whose desktop is gone from a display that is still listed (nothing left to put
    /// back on). Entries of displays that aren't connected — or not in the Space reading — are
    /// kept: the display may come back.
    private func prune(keeping slots: [Slot]) {
        let live = Set(slots.map(\.key))
        let displays = Set(slots.map { Self.displayPart(of: $0.key) })
        for key in store.wallpaperSlots.keys.sorted() where !live.contains(key) && displays.contains(Self.displayPart(of: key)) {
            Log.wallpaper.notice("Forgetting \(self.store.wallpaperSlots[key]?.label ?? key, privacy: .public): that desktop no longer exists")
            store.setWallpaperSlot(nil, forKey: key)
        }
    }

    // MARK: - Helpers

    /// Without the per-Space setter a slot can only be read and written through NSWorkspace, which
    /// sees just the Space on screen: skip it (no capture) unless its screen still shows it now —
    /// the user may have switched since the pass took its snapshot.
    private func reachable(_ slot: Slot) -> Bool {
        service.canPreloadSpaces || service.isShowing(spaceID: slot.spaceID, on: slot.screen)
    }

    private func read(_ slot: Slot) -> SlotPicture? {
        service.readSlot(displayID: slot.displayID, spaceUUID: slot.spaceUUID, spaceID: slot.spaceID,
                         screen: slot.screen, isVisible: slot.isVisible)
    }

    private func write(_ picture: SlotPicture, to slot: Slot) async -> SlotWriteResult {
        await service.writeSlot(picture, displayID: slot.displayID, spaceUUID: slot.spaceUUID, spaceID: slot.spaceID,
                                screen: slot.screen, isVisible: slot.isVisible)
    }

    /// A record kept for later carries the slot's current label, which reports refer to.
    private func relabel(_ entry: WallpaperSlot, on slot: Slot) {
        guard entry.label != slot.label else { return }
        var entry = entry
        entry.label = slot.label
        store.setWallpaperSlot(entry, forKey: slot.key)
    }

    private func forget(_ slot: Slot) {
        store.setWallpaperSlot(nil, forKey: slot.key)
    }

    private func picture(of choice: WallpaperChoice) -> SlotPicture {
        SlotPicture(path: store.fileURL(for: choice).standardizedFileURL.path,
                    placement: choice.placement, fillColor: choice.fillColor)
    }

    /// A wallpaper without an image file of its own (Aerial, live, .madesktop, or the agent's empty
    /// path): never adopted, and put back as a still.
    private func isLive(_ picture: SlotPicture) -> Bool {
        picture.path.isEmpty || service.isSystemPlaceholder(URL(fileURLWithPath: picture.path))
    }

    /// False when there is nothing to put back: no baseline, or the record only adopted a slot that
    /// already showed the picture (its baseline is the applied file itself).
    private func hasPictureToPutBack(_ entry: WallpaperSlot) -> Bool {
        guard let baseline = entry.baseline else { return false }
        let applied = picture(of: entry.applied)
        return URL(fileURLWithPath: baseline.path).standardizedFileURL.path != applied.path
            || baseline.placement != applied.placement
    }

    private static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Slot key = "<DISPLAY-UUID uppercased>|<desktop ruleKey>".
    private func slotKey(_ screen: NSScreen, _ ruleKey: String) -> String {
        "\(displayKey(of: screen))|\(ruleKey)"
    }

    private func displayKey(of screen: NSScreen) -> String {
        (service.displayUUID(of: screen) ?? screen.localizedName).uppercased()
    }

    private static func displayPart(of key: String) -> String {
        String(key[..<(key.lastIndex(of: "|") ?? key.endIndex)])
    }

    private func lock() async {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
    }

    private func unlock() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}
