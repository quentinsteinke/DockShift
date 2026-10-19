// Store.swift — DockShift
// Owns everything DockShift persists under ~/Library/Application Support/DockShift:
//   config.json            DockShiftConfig (profiles, desktop rules, settings)
//   state.json             RuntimeState (what DockShift last did to the Dock)
//   wallpaper-slots.json   [slot key: WallpaperSlot] (what DockShift changed per display × desktop)
//   Docks/<uuid>.plist     DockSnapshot per profile (binary plist, loaded lazily)
//   Wallpapers/<sha>.<ext> content-addressed wallpaper copies (shared by profiles, never GC'd)
//   Original/              the user's setup from first launch, written once
// Every config mutation saves immediately, so a crash or a forced quit never loses an edit.
import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Something DockShift noticed while reading its own files that the user should know about.
struct StoreWarning: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case configRecovered        // config.json didn't decode: moved aside, started fresh
        case configUnreadable       // config.json can't be read (or moved aside): nothing is saved over it
        case slotsRecovered         // wallpaper-slots.json didn't decode: moved aside
        case slotsUnreadable        // wallpaper-slots.json can't be read: nothing is saved over it
        case dock(ProfileID)        // a profile's saved Dock couldn't be read
    }
    var kind: Kind
    var text: String
    /// Worth revealing in Finder: the backup a corrupt file was moved to, or the unreadable file.
    var file: URL?

    var id: Kind { kind }
    /// "Can't read" states last exactly as long as the problem (they are re-checked at every load).
    var isDismissible: Bool { kind != .configUnreadable && kind != .slotsUnreadable }
}

@MainActor @Observable final class Store {
    static let shared = Store(baseDirectory: Store.defaultBaseDirectory)

    let baseDirectory: URL
    var docksDirectory: URL { baseDirectory.appending(path: "Docks", directoryHint: .isDirectory) }
    var wallpapersDirectory: URL { baseDirectory.appending(path: "Wallpapers", directoryHint: .isDirectory) }
    var originalDirectory: URL { baseDirectory.appending(path: "Original", directoryHint: .isDirectory) }

    private(set) var config = DockShiftConfig()
    var runtime = RuntimeState() {
        didSet { if !isLoading { saveRuntime() } }
    }
    /// Wallpaper slots DockShift has changed, keyed "<DISPLAY-UUID>|<desktop ruleKey>". Persisted
    /// separately from config.json: it is bookkeeping, not a user setting, and must never trigger
    /// a reconcile.
    private(set) var wallpaperSlots: [String: WallpaperSlot] = [:]
    /// True when load() found no usable config.json: none yet, or a corrupt one was moved aside
    /// (then `warnings` says so, so it isn't mistaken for a clean first run).
    private(set) var isFirstRun = false
    /// Problems found while reading DockShift's files. Kept apart from save errors so a later
    /// successful save can't erase them before the user has seen them.
    private(set) var warnings: [StoreWarning] = []
    /// The latest write that failed and hasn't succeeded since.
    private(set) var saveError: String?
    /// Profiles whose saved Dock exists but can't be read right now (permissions, I/O). They keep
    /// `hasDock` (the file may come back) but nothing can apply them until it is captured again.
    private(set) var unreadableDockIDs: Set<ProfileID> = []
    /// Called after every config mutation that changed something (not after label refreshes).
    @ObservationIgnored var onConfigChange: (@MainActor () -> Void)?

    @ObservationIgnored private var dockCache: [ProfileID: DockSnapshot] = [:]
    /// Snapshots that failed to read: handled once, not re-read (and re-reported) on every pass.
    @ObservationIgnored private var unreadableDocks: Set<ProfileID> = []
    @ObservationIgnored private var writeFailures: [WriteTarget: String] = [:]
    /// False while config.json exists but couldn't be read: an atomic save would replace the
    /// user's only copy of their profiles with an empty config.
    @ObservationIgnored private var configWritable = true
    /// Same for wallpaper-slots.json, which holds the pictures DockShift has to put back.
    @ObservationIgnored private var slotsWritable = true
    @ObservationIgnored private var isLoading = false
    private var originalExists = false

    /// Internal so a test harness can point the store at a temp directory. Loads right away so
    /// nothing (UI, intents) can ever see — or save over — an unloaded, empty config.
    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        load()
    }

    nonisolated static var defaultBaseDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "DockShift", directoryHint: .isDirectory)
    }

    private var configURL: URL { Self.configURL(in: baseDirectory) }
    private var stateURL: URL { baseDirectory.appending(path: "state.json") }
    private var wallpaperSlotsURL: URL { baseDirectory.appending(path: "wallpaper-slots.json") }
    private var originalDockURL: URL { originalDirectory.appending(path: "dock.plist") }
    /// Written last by saveOriginal, so its presence means "the Original snapshot is complete".
    private var originalWallpaperURL: URL { originalDirectory.appending(path: "wallpaper.json") }
    private func dockURL(for id: ProfileID) -> URL { docksDirectory.appending(path: "\(id.uuidString).plist") }
    private nonisolated static func configURL(in base: URL) -> URL { base.appending(path: "config.json") }

    private enum WriteTarget: Hashable { case config, state, slots, dock, original }

    /// One line for callers that want a single message: a failed save first, then the oldest warning.
    var lastError: String? { saveError ?? warnings.first?.text }

    /// The warning about config.json, if any: the window opens for it like on a first run.
    var configWarning: StoreWarning? {
        warnings.first { $0.kind == .configRecovered || $0.kind == .configUnreadable }
    }

    func isDockUnreadable(_ id: ProfileID) -> Bool { unreadableDockIDs.contains(id) }

    func dismissWarning(_ kind: StoreWarning.Kind) {
        warnings.removeAll { $0.kind == kind && $0.isDismissible }
    }

    // MARK: - Load / save

    /// Reads config.json, state.json and wallpaper-slots.json. A file that doesn't decode is moved
    /// aside (never deleted) and replaced by a fresh default, so one bad write can't keep DockShift
    /// from launching. A file that exists but can't be read at all (permissions, I/O) is left in
    /// place and never saved over.
    func load() {
        isLoading = true
        defer { isLoading = false }
        // "Can't read" states are re-checked from scratch. A recovered-file notice stays until
        // dismissed: Engine.start loads again, and must not hide that init moved config.json aside.
        let transientDocks = unreadableDockIDs
        warnings.removeAll {
            if case .dock(let id) = $0.kind { return transientDocks.contains(id) }
            return !$0.isDismissible
        }
        dockCache.removeAll()
        unreadableDocks.removeAll()
        unreadableDockIDs.removeAll()
        configWritable = true
        slotsWritable = true

        switch readFile(configURL, decode: { try Self.makeDecoder().decode(DockShiftConfig.self, from: $0) }) {
        case .missing:
            isFirstRun = true
            config = DockShiftConfig()
        case .loaded(let loaded):
            isFirstRun = false
            config = loaded
            if normalize() { save() }
        case .corrupt(let backup?, let error):
            // Starts over like a first run (a fresh Default is captured), but says so.
            isFirstRun = true
            config = DockShiftConfig()
            warn(.configRecovered,
                 "DockShift’s settings couldn’t be read (\(error.localizedDescription)), so it started fresh. "
                 + "Your old profiles and rules are kept in \(backup.lastPathComponent).", file: backup)
        case .corrupt(.none, let error), .unreadable(let error):
            isFirstRun = false
            config = DockShiftConfig()
            // Running on empty rules would undo the user's setup (e.g. put wallpapers back), so
            // stay paused until the file can be read again.
            config.settings.paused = true
            configWritable = false
            warn(.configUnreadable,
                 "DockShift can’t read its settings file (\(error.localizedDescription)), so it’s paused and "
                 + "won’t save over it. Fix or move config.json, then reopen DockShift.", file: configURL)
        }

        switch readFile(stateURL, decode: { try Self.makeDecoder().decode(RuntimeState.self, from: $0) }) {
        case .loaded(let state): runtime = state
        // Bookkeeping only: without it the next pass re-checks the Dock instead of trusting it.
        case .missing, .corrupt, .unreadable: runtime = RuntimeState()
        }

        switch readFile(wallpaperSlotsURL, decode: { try Self.makeDecoder().decode([String: WallpaperSlot].self, from: $0) }) {
        case .loaded(let slots):
            wallpaperSlots = slots
        case .missing:
            wallpaperSlots = [:]
        case .corrupt(let backup, let error):
            wallpaperSlots = [:]
            warn(.slotsRecovered,
                 "DockShift’s list of the wallpapers it replaced couldn’t be read (\(error.localizedDescription)), "
                 + "so it can’t put those pictures back by itself."
                 + (backup.map { " The file was kept as \($0.lastPathComponent)." } ?? ""), file: backup)
        case .unreadable(let error):
            wallpaperSlots = [:]
            slotsWritable = false
            warn(.slotsUnreadable,
                 "DockShift can’t read its list of the wallpapers it replaced (\(error.localizedDescription)). "
                 + "It won’t save over it this session.", file: wallpaperSlotsURL)
        }
        originalExists = FileManager.default.fileExists(atPath: originalWallpaperURL.path)
        Log.store.info("Loaded store: \(self.config.profiles.count) profiles, \(self.config.spaceAssignments.count) desktop rules, firstRun=\(self.isFirstRun)")
    }

    /// Atomic write of config.json. Changes stay in memory (and apply) when the file on disk
    /// couldn't be read at load: replacing it would destroy the user's profiles.
    func save() {
        guard configWritable else {
            Log.store.error("Not saving config.json: the file on disk couldn't be read at launch")
            return
        }
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try Self.encodeJSON(config).write(to: configURL, options: .atomic)
            noteWrite(.config, failure: nil)
        } catch {
            noteWrite(.config, failure: "Couldn’t save settings: \(error.localizedDescription)")
        }
    }

    private func saveRuntime() {
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try Self.encodeJSON(runtime).write(to: stateURL, options: .atomic)
            noteWrite(.state, failure: nil)
        } catch {
            noteWrite(.state, failure: "Couldn’t save state: \(error.localizedDescription)")
        }
    }

    /// Records (or with nil forgets) what DockShift did to one wallpaper slot. Saved immediately so
    /// an interrupted pass never loses track of a picture it replaced. Never calls onConfigChange.
    func setWallpaperSlot(_ slot: WallpaperSlot?, forKey key: String) {
        guard wallpaperSlots[key] != slot else { return }
        wallpaperSlots[key] = slot
        guard slotsWritable else { return }
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try Self.encodeJSON(wallpaperSlots).write(to: wallpaperSlotsURL, options: .atomic)
            noteWrite(.slots, failure: nil)
        } catch {
            noteWrite(.slots, failure: "Couldn’t save wallpaper state: \(error.localizedDescription)")
        }
    }

    /// Repairs invariants a hand edit or an interrupted write could break. Returns true if it
    /// changed anything.
    private func normalize() -> Bool {
        var next = config
        var seenDefault = false
        for i in next.profiles.indices {
            if next.profiles[i].isDefault {
                if seenDefault { next.profiles[i].isDefault = false }
                seenDefault = true
            }
            // hasDock without its plist would make the Resolver pick a Dock that can't be applied.
            if next.profiles[i].hasDock, !FileManager.default.fileExists(atPath: dockURL(for: next.profiles[i].id).path) {
                Log.store.error("Dock snapshot missing for profile \(next.profiles[i].id.uuidString, privacy: .public); marking it as inheriting")
                next.profiles[i].hasDock = false
                next.profiles[i].dockCapturedAt = nil
                next.profiles[i].dockRevision += 1
            }
        }
        let ids = Set(next.profiles.map(\.id))
        next.spaceAssignments = next.spaceAssignments.filter { ids.contains($0.value.profileID) }
        guard !Self.sameContent(config, next) else { return false }
        config = next
        return true
    }

    private enum ReadOutcome<T> {
        case loaded(T)
        case missing
        /// The bytes don't decode; the file was moved to `backup` (nil if even that failed).
        case corrupt(backup: URL?, Error)
        /// The file exists but couldn't be read (permissions, I/O). Left untouched.
        case unreadable(Error)
    }

    /// Only a file that reads but doesn't decode is moved aside: a transient read error must not
    /// turn the user's data into a backup nobody looks at.
    private func readFile<T>(_ url: URL, decode: (Data) throws -> T) -> ReadOutcome<T> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if Self.isMissingFile(error) { return .missing }
            Log.store.error("\(url.lastPathComponent, privacy: .public) is unreadable: \(error.localizedDescription, privacy: .public)")
            return .unreadable(error)
        }
        do {
            return .loaded(try decode(data))
        } catch {
            let backup = url.deletingLastPathComponent()
                .appending(path: "\(url.lastPathComponent).corrupt-\(Self.backupStamp())")
            let moved = (try? FileManager.default.moveItem(at: url, to: backup)) != nil
            Log.store.error("\(url.lastPathComponent, privacy: .public) doesn't decode (\(error.localizedDescription, privacy: .public)); \(moved ? "moved to \(backup.lastPathComponent)" : "couldn't move it aside", privacy: .public)")
            return .corrupt(backup: moved ? backup : nil, error)
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        guard let code = (error as? CocoaError)?.code else { return false }
        return code == .fileReadNoSuchFile || code == .fileNoSuchFile
    }

    /// One warning per kind: a newer one replaces the old text.
    private func warn(_ kind: StoreWarning.Kind, _ text: String, file: URL? = nil) {
        Log.store.error("\(text, privacy: .public)")
        warnings.removeAll { $0.kind == kind }
        warnings.append(StoreWarning(kind: kind, text: text, file: file))
    }

    private func clearWarning(_ kind: StoreWarning.Kind) {
        if warnings.contains(where: { $0.kind == kind }) { warnings.removeAll { $0.kind == kind } }
    }

    /// A success clears only the failure of the same file, so e.g. a state.json write can't hide
    /// that config.json couldn't be saved.
    private func noteWrite(_ target: WriteTarget, failure: String?) {
        if let failure {
            Log.store.error("\(failure, privacy: .public)")
            writeFailures[target] = failure
            saveError = failure
        } else if writeFailures.removeValue(forKey: target) != nil {
            saveError = writeFailures.values.first
        }
    }

    // MARK: - Profiles

    /// Default first, then by creation date.
    var profiles: [Profile] { Self.ordered(config.profiles) }
    var defaultProfile: Profile? { config.profiles.first { $0.isDefault } }
    var settings: AppSettings { config.settings }

    func profile(_ id: ProfileID?) -> Profile? {
        guard let id else { return nil }
        return config.profiles.first { $0.id == id }
    }

    /// `isDefault` is honoured only while no Default exists, keeping exactly one Default.
    @discardableResult
    func createProfile(name: String, isDefault: Bool) -> Profile {
        let profile = Profile(id: ProfileID(), name: Self.cleanName(name),
                              isDefault: isDefault && defaultProfile == nil,
                              hasDock: false, dockRevision: 0, dockCapturedAt: nil, wallpaper: nil,
                              createdAt: Self.wholeSeconds(Date()))
        mutate { $0.profiles.append(profile) }
        Log.store.info("Created profile \(profile.id.uuidString, privacy: .public) default=\(profile.isDefault)")
        return profile
    }

    /// No-op for Default: it is always called "Default".
    func renameProfile(_ id: ProfileID, to name: String) {
        guard let p = profile(id), !p.isDefault else { return }
        let clean = Self.cleanName(name)
        updateProfile(id) { $0.name = clean }
    }

    /// No-op for Default. Also removes its Dock snapshot and every desktop rule that used it.
    func deleteProfile(_ id: ProfileID) {
        guard let p = profile(id), !p.isDefault else { return }
        mutate {
            $0.profiles.removeAll { $0.id == id }
            $0.spaceAssignments = $0.spaceAssignments.filter { $0.value.profileID != id }
        }
        dockCache[id] = nil
        unreadableDocks.remove(id)
        unreadableDockIDs.remove(id)
        clearWarning(.dock(id))
        try? FileManager.default.removeItem(at: dockURL(for: id))
        Log.store.info("Deleted profile \(id.uuidString, privacy: .public)")
    }

    private func updateProfile(_ id: ProfileID, notify: Bool = true, _ body: (inout Profile) -> Void) {
        mutate(notify: notify) { config in
            guard let i = config.profiles.firstIndex(where: { $0.id == id }) else { return }
            body(&config.profiles[i])
        }
    }

    // MARK: - Dock snapshots

    /// Loaded lazily from Docks/<id>.plist and cached. nil when the profile inherits its Dock.
    func dockSnapshot(for id: ProfileID) -> DockSnapshot? {
        guard let p = profile(id), p.hasDock else { return nil }
        if let cached = dockCache[id] { return cached }
        guard !unreadableDocks.contains(id) else { return nil }
        switch readFile(dockURL(for: id), decode: { try PropertyListDecoder().decode(DockSnapshot.self, from: $0) }) {
        case .loaded(let snapshot):
            dockCache[id] = snapshot
            return snapshot
        case .missing:
            unreadableDocks.insert(id)
            dropUnreadableDock(id, text: "The Dock saved in “\(p.name)” is missing. Capture the Dock again to use it in this profile.", file: nil)
        case .corrupt(let backup, _):
            unreadableDocks.insert(id)
            dropUnreadableDock(id, text: "The Dock saved in “\(p.name)” couldn’t be read, so DockShift set it aside. Capture the Dock again to use it in this profile.", file: backup)
        case .unreadable(let error):
            unreadableDocks.insert(id)
            let text = "The Dock saved in “\(p.name)” can’t be read right now (\(error.localizedDescription)). Capture the Dock again to replace it."
            let file = dockURL(for: id)
            // Deferred like dropUnreadableDock: this runs mid-pass and from view tasks.
            Task { @MainActor [weak self] in
                guard let self, self.unreadableDocks.contains(id) else { return }
                self.unreadableDockIDs.insert(id)
                self.warn(.dock(id), text, file: file)
            }
        }
        return nil
    }

    /// A Dock that is gone for good stops claiming the Dock channel (`hasDock = false`), so the
    /// Resolver falls through to the next rule instead of picking a layout nothing can apply.
    /// Deferred: dockSnapshot(for:) runs in the middle of a reconcile, which must not re-enter
    /// itself through onConfigChange.
    private func dropUnreadableDock(_ id: ProfileID, text: String, file: URL?) {
        Task { @MainActor [weak self] in
            // A capture in the meantime replaced the file: nothing to drop.
            guard let self, self.dockCache[id] == nil, self.profile(id)?.hasDock == true else { return }
            self.updateProfile(id) {
                $0.hasDock = false
                $0.dockRevision += 1
                $0.dockCapturedAt = nil
            }
            self.warn(.dock(id), text, file: file)
        }
    }

    private func readDockFile(_ id: ProfileID) throws -> DockSnapshot {
        try PropertyListDecoder().decode(DockSnapshot.self, from: Data(contentsOf: dockURL(for: id)))
    }

    /// nil clears the profile's Dock (inherit). The plist is written before config.json, so an
    /// interrupted write leaves at worst an unused file, never `hasDock` without a snapshot.
    func setDockSnapshot(_ snapshot: DockSnapshot?, for id: ProfileID) {
        guard let p = profile(id) else { return }
        let url = dockURL(for: id)
        if let snapshot {
            if p.hasDock, (dockCache[id] ?? (try? readDockFile(id))) == snapshot { return }
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try FileManager.default.createDirectory(at: docksDirectory, withIntermediateDirectories: true)
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                noteWrite(.dock, failure: "Couldn’t save the Dock for “\(p.name)”: \(error.localizedDescription)")
                return
            }
            noteWrite(.dock, failure: nil)
            dockCache[id] = snapshot
            unreadableDocks.remove(id)
            unreadableDockIDs.remove(id)
            clearWarning(.dock(id))
            updateProfile(id) {
                $0.hasDock = true
                $0.dockRevision += 1
                $0.dockCapturedAt = Self.wholeSeconds(snapshot.capturedAt)
            }
        } else {
            dockCache[id] = nil
            unreadableDocks.remove(id)
            unreadableDockIDs.remove(id)
            clearWarning(.dock(id))
            try? FileManager.default.removeItem(at: url)
            guard p.hasDock else { return }
            updateProfile(id) {
                $0.hasDock = false
                $0.dockRevision += 1
                $0.dockCapturedAt = nil
            }
        }
        Log.store.info("Dock for profile \(id.uuidString, privacy: .public) \(snapshot == nil ? "cleared" : "saved", privacy: .public)")
    }

    // MARK: - Wallpapers

    func setWallpaper(_ choice: WallpaperChoice?, for id: ProfileID) {
        updateProfile(id) { $0.wallpaper = choice }
    }

    /// Copies the image into Wallpapers/<sha256>.<ext> so later edits/moves of the user's file
    /// don't matter and WallpaperAgent never has to read a TCC-protected folder. Identical bytes
    /// share one file. Does not touch config: pass the result to setWallpaper.
    /// Re-ingesting a file DockShift already manages (e.g. "Use Current Wallpaper" right after
    /// DockShift set it) keeps the name the user picked instead of showing the hash.
    func ingestWallpaper(from url: URL, placement: Placement, fillColor: RGBColor) throws -> WallpaperChoice {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? Self.sniffExtension(data) : url.pathExtension.lowercased()
        let fileName = ext.isEmpty ? hex : "\(hex).\(ext)"
        let destination = wallpapersDirectory.appending(path: fileName)

        // Same name = same bytes, unless an earlier copy was cut short: re-copy on size mismatch.
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue
        if existingSize != data.count {
            try FileManager.default.createDirectory(at: wallpapersDirectory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            Log.store.info("Ingested wallpaper \(fileName, privacy: .public) (\(data.count) bytes)")
        }
        let isManaged = url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
            == wallpapersDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let known = isManaged ? config.profiles.lazy.compactMap(\.wallpaper).first { $0.fileName == fileName }?.displayName : nil
        return WallpaperChoice(fileName: fileName, displayName: known ?? url.lastPathComponent,
                               placement: placement, fillColor: fillColor)
    }

    func fileURL(for choice: WallpaperChoice) -> URL {
        // lastPathComponent: a hand-edited config must not point outside Wallpapers/.
        wallpapersDirectory.appending(path: (choice.fileName as NSString).lastPathComponent)
    }

    func wallpaperFileExists(_ choice: WallpaperChoice) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL(for: choice).path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// For a source without an extension: ask ImageIO what the bytes are.
    private static func sniffExtension(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension else { return "" }
        return ext.lowercased()
    }

    // MARK: - Settings & desktop rules

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        mutate { change(&$0.settings) }
    }

    func assignment(forSpaceKey key: String) -> SpaceAssignment? {
        config.spaceAssignments[key]
    }

    /// nil removes the rule. A rule for a profile that doesn't exist is ignored.
    func setAssignment(profileID: ProfileID?, spaceKey: String, displayIdentifier: String, label: String) {
        if let profileID {
            guard profile(profileID) != nil else {
                Log.store.error("Ignoring desktop rule for unknown profile \(profileID.uuidString, privacy: .public)")
                return
            }
            let rule = SpaceAssignment(profileID: profileID, displayIdentifier: displayIdentifier, lastSeenLabel: label)
            mutate { $0.spaceAssignments[spaceKey] = rule }
        } else {
            mutate { $0.spaceAssignments[spaceKey] = nil }
        }
    }

    /// Keeps the informational label/display current as desktops are reordered. Saves but does
    /// not notify: a label is not a rule change and must not trigger a reconcile.
    func refreshAssignmentLabel(spaceKey: String, displayIdentifier: String, label: String) {
        mutate(notify: false) {
            guard var rule = $0.spaceAssignments[spaceKey] else { return }
            rule.displayIdentifier = displayIdentifier
            rule.lastSeenLabel = label
            $0.spaceAssignments[spaceKey] = rule
        }
    }

    // MARK: - Original setup

    var hasOriginal: Bool { originalExists }

    /// Only the first call writes anything: the Original is the user's pre-DockShift setup and
    /// must survive every later capture.
    func saveOriginal(dock: DockSnapshot?, wallpaper: WallpaperChoice?) {
        guard !hasOriginal else { return }
        do {
            try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
            if let dock {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(dock).write(to: originalDockURL, options: .atomic)
            }
            let record = OriginalWallpaper(wallpaper: wallpaper, capturedAt: Self.wholeSeconds(Date()))
            try Self.encodeJSON(record).write(to: originalWallpaperURL, options: .atomic)
            originalExists = true
            noteWrite(.original, failure: nil)
            Log.store.info("Saved original setup (dock=\(dock != nil), wallpaper=\(wallpaper != nil))")
        } catch {
            noteWrite(.original, failure: "Couldn’t save the original Dock & wallpaper: \(error.localizedDescription)")
        }
    }

    func originalDock() -> DockSnapshot? {
        guard let data = try? Data(contentsOf: originalDockURL) else { return nil }
        return try? PropertyListDecoder().decode(DockSnapshot.self, from: data)
    }

    /// wallpaper.json is now only the Original's completion marker: wallpapers are put back per
    /// slot (wallpaperSlots' baselines), not from one picture captured at first launch. Older
    /// builds stored that picture here; it is never read.
    private struct OriginalWallpaper: Codable {
        var wallpaper: WallpaperChoice?
        var capturedAt: Date
    }

    // MARK: - Intents

    /// Any thread. App Intents (System Settings › Focus, Shortcuts) may query profiles before
    /// the app has finished launching, so this parses config.json directly instead of touching
    /// the main-actor store.
    nonisolated static func profileSummariesFromDisk() -> [ProfileSummary] {
        profileSummaries(fromConfigAt: configURL(in: defaultBaseDirectory))
    }

    nonisolated static func profileSummaries(fromConfigAt url: URL) -> [ProfileSummary] {
        guard let data = try? Data(contentsOf: url),
              let config = try? makeDecoder().decode(DockShiftConfig.self, from: data) else { return [] }
        return ordered(config.profiles).map { ProfileSummary(id: $0.id, name: $0.name, isDefault: $0.isDefault) }
    }

    // MARK: - Helpers

    /// Applies a change to a copy of the config; saves and notifies only if the content changed.
    private func mutate(notify: Bool = true, _ body: (inout DockShiftConfig) -> Void) {
        var next = config
        body(&next)
        guard !Self.sameContent(config, next) else { return }
        config = next
        save()
        if notify { onConfigChange?() }
    }

    /// DockShiftConfig isn't Equatable (Models.swift), and comparing field by field would
    /// silently stop saving any field added later; the canonical encoding covers everything.
    private static func sameContent(_ a: DockShiftConfig, _ b: DockShiftConfig) -> Bool {
        guard let ea = try? encodeJSON(a), let eb = try? encodeJSON(b) else { return false }
        return ea == eb
    }

    private nonisolated static func ordered(_ profiles: [Profile]) -> [Profile] {
        profiles.enumerated().sorted { l, r in
            if l.element.isDefault != r.element.isDefault { return l.element.isDefault }
            if l.element.createdAt != r.element.createdAt { return l.element.createdAt < r.element.createdAt }
            return l.offset < r.offset
        }.map(\.element)
    }

    private static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Profile" : trimmed
    }

    /// `.iso8601` JSON dates drop sub-seconds; truncating up front keeps memory == disk.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func backupStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
