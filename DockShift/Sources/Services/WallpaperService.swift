// WallpaperService.swift — DockShift
// Reads and writes desktop pictures per slot (display × Space). Every Space — visible or not,
// Desktop 1's empty uuid included — goes through private HIServices API resolved with dlsym; on
// 27.2 a write lands on that one Space only, ~0.3–1.5 s later (measured). A macOS that drops it
// degrades to public NSWorkspace API for the visible Space of each screen; other desktops are then
// written when they are next visible.
// The wallpaper store (Index.plist) is only ever READ: writing it needs a WallpaperAgent restart
// (black flash on every display) and races the agent's in-memory copy.
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

struct CurrentWallpaper: Sendable {
    var url: URL
    var placement: Placement
    var fillColor: RGBColor
}

enum SlotWriteResult: Sendable, Equatable {
    case written
    /// Not on screen (or no longer) and no per-Space API: the desktop gets the picture when it is
    /// next visible. Nothing was written.
    case deferred
    /// Issued, but macOS didn't report the new picture in time: it may still land.
    case unconfirmed
    /// Not written. Human-readable reason.
    case failed(String)
}

// MARK: - Private API shim

private enum DesktopPictureSPI {
    /// (CGDirectDisplayID, 0, spaceUUID) -> retained dict {ImageFilePath, Placement, BackgroundColor, …}.
    typealias CopyForSpaceFn = @convention(c) (UInt32, Int32, CFString) -> Unmanaged<CFDictionary>?
    /// (CGDirectDisplayID, config, 0, 0, spaceUUID). Returns nothing; WallpaperAgent applies it later.
    typealias SetForSpaceFn = @convention(c) (UInt32, CFDictionary, Int32, Int32, CFString) -> Void

    nonisolated(unsafe) private static let handle = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)

    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static let copyForSpace = sym("DesktopPictureCopyDisplayForSpace", as: CopyForSpaceFn.self)
    static let setForSpace = sym("DesktopPictureSetDisplayForSpace", as: SetForSpaceFn.self)

    /// macOS 27's sandboxed WallpaperAgent resolves relative paths inside its own container, so it
    /// needs absolute ones. Through macOS 26 the setter mangled absolute home paths into "/~…" and
    /// had to be sent root-relative paths instead (per WallpaperMachine; only 27.2 was examined here).
    static let takesAbsolutePaths = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    /// Readbacks come back absolute, "/~/…", root-relative or as file URLs depending on the OS.
    static func normalize(_ raw: String) -> String {
        var path = raw
        if path.hasPrefix("file:"), let url = URL(string: path), url.isFileURL { path = url.path }
        if path.hasPrefix("/~") { path.removeFirst() }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = "/" + path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

// MARK: - Service

@MainActor
final class WallpaperService {
    static let shared = WallpaperService()
    private init() {}

    /// What NSWorkspace reports for Aerials and Apple's live wallpapers, which have no image file.
    /// On 27.2 DefaultDesktop.heic is a symlink to /System/Library/Wallpapers/.default/DefaultAerial.heic.
    private static let placeholderNames: Set<String> = ["defaultdesktop.heic", "defaultaerial.heic"]
    private static let placeholderDirectory = "/System/Library/Wallpapers/.default/"
    private static let defaultDesktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    private static let storeIndexURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    /// The setter applies asynchronously (≤ ~1.5 s measured on 27.2); allow twice that.
    private static let confirmPolls = 30
    private static let pollInterval = Duration.milliseconds(100)

    /// The private per-Space setter and getter are both there: every desktop can be read and
    /// written, visible or not.
    var canPreloadSpaces: Bool { DesktopPictureSPI.setForSpace != nil && DesktopPictureSPI.copyForSpace != nil }

    // MARK: Displays

    func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Stable across reboots and reconnects (unlike CGDirectDisplayID or the NSScreen index), and
    /// the same string SkyLight uses as "Display Identifier" when displays have separate Spaces.
    func displayUUID(of screen: NSScreen) -> String? {
        guard let id = displayID(of: screen),
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return string as String
    }

    /// "Main" is SkyLight's single Space group when "Displays have separate Spaces" is off: every
    /// screen shows the same Space then.
    func screens(forDisplayIdentifier id: String) -> [NSScreen] {
        if id == "Main" { return NSScreen.screens }
        return NSScreen.screens.filter { displayUUID(of: $0)?.caseInsensitiveCompare(id) == .orderedSame }
    }

    // MARK: Reading

    func currentWallpaper(for screen: NSScreen) -> CurrentWallpaper? {
        let ws = NSWorkspace.shared
        guard let url = ws.desktopImageURL(for: screen), url.isFileURL else {
            Log.wallpaper.notice("No file wallpaper on \(screen.localizedName, privacy: .public)")
            return nil
        }
        if isSystemPlaceholder(url) {
            Log.wallpaper.notice("\(screen.localizedName, privacy: .public) shows an Aerial/live wallpaper (no image file)")
            return nil
        }
        guard isImageFile(url) else {
            Log.wallpaper.notice("Wallpaper on \(screen.localizedName, privacy: .public) is not a readable image: \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        let options = ws.desktopImageOptions(for: screen) ?? [:]
        return CurrentWallpaper(url: url, placement: Self.placement(from: options),
                                fillColor: Self.fillColor(from: options) ?? .black)
    }

    /// Aerial / live wallpaper stand-ins, including Apple's .madesktop descriptors (XML, no image).
    func isSystemPlaceholder(_ url: URL) -> Bool {
        [url.standardizedFileURL, url.resolvingSymlinksInPath()].contains { u in
            Self.placeholderNames.contains(u.lastPathComponent.lowercased()) || u.path.hasPrefix(Self.placeholderDirectory)
                || u.pathExtension.lowercased() == "madesktop"
        }
    }

    /// A still image to put back for a wallpaper without an image file (Aerial, live, .madesktop,
    /// or an empty path from the agent): the placeholder's own target when it resolves to one, else
    /// what DefaultDesktop.heic resolves to — on 27.2 both are .default/DefaultAerial.heic, a still
    /// of the default wallpaper. nil when there is none.
    func stillImage(standingInFor path: String) -> URL? {
        for candidate in (path.isEmpty ? [] : [URL(fileURLWithPath: path)]) + [Self.defaultDesktopURL] {
            let real = candidate.resolvingSymlinksInPath().standardizedFileURL
            if isImageFile(real) { return real }
        }
        return nil
    }

    /// True when `source` is still the picture `copy` was made from: same size and either last
    /// modified before the copy was written (a content-addressed copy is written once, at or before
    /// the capture that hashed `source` to it, so its bytes can't have changed since) or byte-identical.
    func isUnchanged(source: String, copy: String) -> Bool {
        let fm = FileManager.default
        let rs = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
        let rc = URL(fileURLWithPath: copy).resolvingSymlinksInPath().path
        guard let s = try? fm.attributesOfItem(atPath: rs), let c = try? fm.attributesOfItem(atPath: rc),
              let size = (s[.size] as? NSNumber)?.int64Value, size == (c[.size] as? NSNumber)?.int64Value
        else { return false }
        if let ms = s[.modificationDate] as? Date, let mc = c[.modificationDate] as? Date, ms < mc { return true }
        return fm.contentsEqual(atPath: rs, andPath: rc)
    }

    /// Whether `screen` still shows the Space with this ManagedSpaceID (nil = identity unknown, no
    /// Space API: assumed). NSWorkspace only sees the Space on screen, and the user may have
    /// switched since the caller's snapshot, so this re-reads SkyLight right before each use.
    func isShowing(spaceID: UInt64?, on screen: NSScreen) -> Bool {
        guard let spaceID else { return true }
        guard let current = SpaceReader.snapshot()?.currentByDisplay else { return false }
        if let shared = current["Main"] { return shared == spaceID }
        guard let uuid = displayUUID(of: screen) else { return false }
        return current.contains { $0.key.caseInsensitiveCompare(uuid) == .orderedSame && $0.value == spaceID }
    }

    /// Only plain image files can be copied and re-applied; .madesktop stubs, videos and folders can't.
    func isImageFile(_ url: URL) -> Bool {
        Self.isRegularFile(url) && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// What one slot shows. `spaceUUID` nil = the visible Space of `screen` with unknown identity
    /// (no Space API); `spaceID` is the slot's ManagedSpaceID, checked before NSWorkspace is asked.
    /// A slot showing something without an image file reads back with an empty path; nil = it
    /// couldn't be read at all (incl. a visible-only read whose screen has moved to another Space).
    /// The agent's per-Space answer is right in both store modes (verified on 27.2): per Space once
    /// desktops have their own pictures, and the global picture — which every Space then shows —
    /// while "Show on all Spaces" is on.
    func readSlot(displayID: CGDirectDisplayID, spaceUUID: String?, spaceID: UInt64? = nil,
                  screen: NSScreen?, isVisible: Bool) -> SlotPicture? {
        func visible() -> SlotPicture? {
            guard isVisible, let screen, isShowing(spaceID: spaceID, on: screen) else { return nil }
            return visiblePicture(on: screen)
        }
        guard let spaceUUID, let agent = agentPicture(displayID: displayID, spaceUUID: spaceUUID) else { return visible() }
        let shown = agent.path.isEmpty || agent.placement == nil || agent.fillColor == nil ? visible() : nil
        if agent.path.isEmpty, let shown { return shown }
        return SlotPicture(path: agent.path, placement: agent.placement ?? shown?.placement ?? .fill,
                           fillColor: agent.fillColor ?? shown?.fillColor ?? .black)
    }

    /// The one "already shows it" test: the same file (path, resolved symlinks, or identical bytes —
    /// the user's file and DockShift's copy of it are the same picture), the same placement, and the
    /// same fill colour where one is visible (fit/center). Agent colour round trips aren't bit-exact.
    func shows(_ current: SlotPicture, _ target: SlotPicture) -> Bool {
        guard !current.path.isEmpty, !target.path.isEmpty, current.placement == target.placement else { return false }
        if target.placement == .fit || target.placement == .center,
           !Self.sameColor(current.fillColor, target.fillColor) { return false }
        return Self.samePath(current.path, target.path) || Self.sameContents(current.path, target.path)
    }

    /// Read-only. "Show on all Spaces" is on while the store has no per-Space nodes; top-level
    /// Displays entries are per-display pictures for every Space of that display.
    /// nil when the store can't be read or has an unknown layout. NEVER write this file.
    func showOnAllSpaces() -> Bool? {
        guard let data = try? Data(contentsOf: Self.storeIndexURL),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        let spaces = root["Spaces"] as? [String: Any]
        let displays = root["Displays"] as? [String: Any]
        guard spaces != nil || displays != nil || root["AllSpacesAndDisplays"] != nil else { return nil }
        return (spaces?.isEmpty ?? true) && (root["AllSpacesAndDisplays"] is [String: Any] || !(displays?.isEmpty ?? true))
    }

    // MARK: Writing

    /// Sets the picture of the Space currently visible on `screen` through NSWorkspace. Returns false
    /// (no write) when it already shows it: repeated sets get coalesced or dropped by the OS.
    @discardableResult
    func setVisible(fileURL: URL, placement: Placement, fillColor: RGBColor, on screen: NSScreen) throws -> Bool {
        let target = fileURL.standardizedFileURL
        if let current = visiblePicture(on: screen),
           shows(current, SlotPicture(path: target.path, placement: placement, fillColor: fillColor)) {
            Log.wallpaper.debug("\(screen.localizedName, privacy: .public) already shows \(target.lastPathComponent, privacy: .public)")
            return false
        }
        guard target.isFileURL, Self.isRegularFile(target) else {
            Log.wallpaper.error("Wallpaper file missing: \(target.path, privacy: .public)")
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: target.path])
        }
        do {
            // Always pass all three keys: omitted ones fall back to Fit, not Fill.
            try NSWorkspace.shared.setDesktopImageURL(target, for: screen,
                                                      options: Self.workspaceOptions(placement: placement, fillColor: fillColor))
        } catch {
            Log.wallpaper.error("setDesktopImageURL failed on \(screen.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        Log.wallpaper.info("Set \(target.lastPathComponent, privacy: .public) (\(placement.rawValue, privacy: .public)) on \(screen.localizedName, privacy: .public)")
        return true
    }

    /// Writes one slot and waits (≤ 3 s) until macOS reports the new picture. `spaceUUID` "" is
    /// Desktop 1; nil = the visible Space of `screen` with unknown identity. Without the per-Space
    /// API only the Space on screen can be written, and only while `screen` still shows `spaceID`.
    /// Once a write is issued it is confirmed even if the calling task is cancelled meanwhile: the
    /// caller needs to know whether it landed to keep its bookkeeping right.
    func writeSlot(_ picture: SlotPicture, displayID: CGDirectDisplayID, spaceUUID: String?, spaceID: UInt64? = nil,
                   screen: NSScreen?, isVisible: Bool) async -> SlotWriteResult {
        let url = URL(fileURLWithPath: picture.path).standardizedFileURL
        guard !picture.path.isEmpty, Self.isRegularFile(url) else {
            Log.wallpaper.error("Not writing missing file \(picture.path, privacy: .public)")
            return .failed("the picture file is missing (\(url.lastPathComponent))")
        }
        guard NSScreen.screens.contains(where: { self.displayID(of: $0) == displayID }) else {
            Log.wallpaper.error("Not writing: display \(displayID) is not connected")
            return .failed("the display is not connected")
        }
        let target = SlotPicture(path: url.path, placement: picture.placement, fillColor: picture.fillColor)
        if let spaceUUID, let set = DesktopPictureSPI.setForSpace, DesktopPictureSPI.copyForSpace != nil {
            return await writeSpace(target, displayID: displayID, spaceUUID: spaceUUID, set: set)
        }
        guard isVisible, let screen, isShowing(spaceID: spaceID, on: screen) else {
            Log.wallpaper.info("Space \(spaceUUID ?? "?", privacy: .public) on display \(displayID) isn't visible and can't be written now")
            return .deferred
        }
        return await writeVisible(target, on: screen)
    }

    // MARK: Helpers

    private struct AgentPicture {
        var path: String            // "" = no image file
        var placement: Placement?
        var fillColor: RGBColor?
    }

    private func writeSpace(_ target: SlotPicture, displayID: CGDirectDisplayID, spaceUUID: String,
                            set: DesktopPictureSPI.SetForSpaceFn) async -> SlotWriteResult {
        let before = agentPicture(displayID: displayID, spaceUUID: spaceUUID)
        let config: [String: Any] = [
            "ImageFilePath": DesktopPictureSPI.takesAbsolutePaths ? target.path : String(target.path.dropFirst()),
            "Placement": target.placement.rawValue,
            "BackgroundColor": Self.genericComponents(target.fillColor),
        ]
        set(displayID, config as CFDictionary, 0, 0, spaceUUID as CFString)

        // A colour-only change can't be confirmed by file and placement, which matched before the write.
        let fileAlreadyThere = before.map { agentMatches($0, target) } ?? false
        var lastSeen: String?
        for poll in 1...Self.confirmPolls {
            await Self.pause(Self.pollInterval)
            guard let seen = agentPicture(displayID: displayID, spaceUUID: spaceUUID) else { continue }
            lastSeen = seen.path
            guard agentMatches(seen, target) else { continue }
            let colourVisible = target.placement == .fit || target.placement == .center
            let colourMatches = !colourVisible || seen.fillColor.map { Self.sameColor($0, target.fillColor) } ?? false
            if !fileAlreadyThere || colourMatches || poll >= 5 {
                Log.wallpaper.info("Set \(URL(fileURLWithPath: target.path).lastPathComponent, privacy: .public) (\(target.placement.rawValue, privacy: .public)) on Space \"\(spaceUUID, privacy: .public)\" (display \(displayID))")
                return .written
            }
        }
        Log.wallpaper.error("Write to Space \"\(spaceUUID, privacy: .public)\" (display \(displayID)) not confirmed; agent reports \(lastSeen ?? "nothing", privacy: .public)")
        return .unconfirmed
    }

    private func writeVisible(_ target: SlotPicture, on screen: NSScreen) async -> SlotWriteResult {
        do {
            try setVisible(fileURL: URL(fileURLWithPath: target.path), placement: target.placement,
                           fillColor: target.fillColor, on: screen)
        } catch {
            return .failed(error.localizedDescription)
        }
        for poll in 0...Self.confirmPolls {
            if poll > 0 { await Self.pause(Self.pollInterval) }
            if let seen = visiblePicture(on: screen), Self.samePath(seen.path, target.path),
               seen.placement == target.placement { return .written }
        }
        Log.wallpaper.error("Write to \(screen.localizedName, privacy: .public) not confirmed")
        return .unconfirmed
    }

    /// Same file and (when the agent reports one) the same placement id.
    private func agentMatches(_ seen: AgentPicture, _ target: SlotPicture) -> Bool {
        Self.samePath(seen.path, target.path) && (seen.placement ?? target.placement) == target.placement
    }

    private func agentPicture(displayID: CGDirectDisplayID, spaceUUID: String) -> AgentPicture? {
        guard let copy = DesktopPictureSPI.copyForSpace,
              let dict = copy(displayID, 0, spaceUUID as CFString)?.takeRetainedValue() as? [String: Any]
        else { return nil }
        let raw = dict["ImageFilePath"] as? String ?? ""
        return AgentPicture(path: raw.isEmpty ? "" : DesktopPictureSPI.normalize(raw),
                            placement: (dict["Placement"] as? String).flatMap(Placement.init(rawValue:)),
                            fillColor: Self.srgbColor(fromGeneric: dict["BackgroundColor"]))
    }

    private func visiblePicture(on screen: NSScreen) -> SlotPicture? {
        let ws = NSWorkspace.shared
        guard let url = ws.desktopImageURL(for: screen) else { return nil }
        let options = ws.desktopImageOptions(for: screen) ?? [:]
        return SlotPicture(path: url.isFileURL ? url.standardizedFileURL.path : "",
                           placement: Self.placement(from: options), fillColor: Self.fillColor(from: options) ?? .black)
    }

    /// Sleeps even when the task is cancelled (see writeSlot).
    private static func pause(_ duration: Duration) async {
        await Task.detached { try? await Task.sleep(for: duration) }.value
    }

    private static func workspaceOptions(placement: Placement, fillColor: RGBColor) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        let scaling: NSImageScaling = switch placement {
        case .fill, .fit: .scaleProportionallyUpOrDown
        case .stretch: .scaleAxesIndependently
        case .center: .scaleNone
        }
        let c = fillColor.clamped
        return [.imageScaling: NSNumber(value: scaling.rawValue),
                .allowClipping: NSNumber(value: placement == .fill),
                .fillColor: NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)]
    }

    /// The per-Space dict carries generic (calibrated) RGB, like the store's EncodedOptionValues: on
    /// 27.2 its BackgroundColor reads back as the same numbers NSWorkspace reports as
    /// NSCalibratedRGB. RGBColor is sRGB, so convert or per-Space and visible fills would differ.
    private static func genericComponents(_ color: RGBColor) -> [Double] {
        let c = color.clamped
        guard let g = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1).usingColorSpace(.genericRGB)
        else { return [c.red, c.green, c.blue] }
        return [g.redComponent, g.greenComponent, g.blueComponent].map { min(max(Double($0), 0), 1) }
    }

    private static func srgbColor(fromGeneric value: Any?) -> RGBColor? {
        guard let c = value as? [NSNumber], c.count >= 3,
              let s = NSColor(calibratedRed: CGFloat(c[0].doubleValue), green: CGFloat(c[1].doubleValue),
                              blue: CGFloat(c[2].doubleValue), alpha: 1).usingColorSpace(.sRGB)
        else { return nil }
        return RGBColor(red: Double(s.redComponent), green: Double(s.greenComponent), blue: Double(s.blueComponent)).clamped
    }

    /// Fill Screen [Crop] = scaling 3 + clipping (verified on 27.2), Fit [SizeToFit] = 3 without,
    /// Stretch [FillScreen] = 1, Center [Centered] = 2. Missing keys mean scaling 3, no clipping.
    private static func placement(from options: [NSWorkspace.DesktopImageOptionKey: Any]) -> Placement {
        let scaling = (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        switch NSImageScaling(rawValue: scaling) {
        case .scaleAxesIndependently: return .stretch
        case .scaleNone: return .center
        default: return clipping ? .fill : .fit    // also the unsupported scaleProportionallyDown
        }
    }

    /// The agent stores the colour as generic RGB and reports it calibrated, so convert to sRGB.
    private static func fillColor(from options: [NSWorkspace.DesktopImageOptionKey: Any]) -> RGBColor? {
        guard let c = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) else { return nil }
        return RGBColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent)).clamped
    }

    private static func sameColor(_ a: RGBColor, _ b: RGBColor) -> Bool {
        let a = a.clamped, b = b.clamped
        return abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let ua = URL(fileURLWithPath: a), ub = URL(fileURLWithPath: b)
        return ua.standardizedFileURL.path == ub.standardizedFileURL.path
            || ua.resolvingSymlinksInPath().path == ub.resolvingSymlinksInPath().path
    }

    /// Size first: a byte comparison only runs for same-size files. Symlinks are resolved up front
    /// (attributesOfItem and contentsEqual look at a link itself, not its target).
    private static func sameContents(_ a: String, _ b: String) -> Bool {
        let fm = FileManager.default
        let ra = URL(fileURLWithPath: a).resolvingSymlinksInPath().path
        let rb = URL(fileURLWithPath: b).resolvingSymlinksInPath().path
        func size(_ path: String) -> Int64? { ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value }
        guard let sa = size(ra), sa == size(rb) else { return false }
        return fm.contentsEqual(atPath: ra, andPath: rb)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

private extension RGBColor {
    var clamped: RGBColor {
        RGBColor(red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1))
    }
}
