// Compile this harness with production Models, SpaceMonitor, Log and WallpaperSync.
// The Store and WallpaperService doubles never touch desktop preferences or user data.
import AppKit

@MainActor final class Store {
    static let shared = Store()
    var wallpaperSlots: [String: WallpaperSlot] = [:]
    func wallpaperFileExists(_ choice: WallpaperChoice) -> Bool { true }
    func setWallpaperSlot(_ slot: WallpaperSlot?, forKey key: String) { wallpaperSlots[key] = slot }
    func fileURL(for choice: WallpaperChoice) -> URL { URL(fileURLWithPath: "/tmp/" + choice.fileName) }
    func ingestWallpaper(from url: URL, placement: Placement, fillColor: RGBColor) throws -> WallpaperChoice {
        WallpaperChoice(fileName: "saved-baseline.png", displayName: "Saved baseline")
    }
}
enum SlotWriteResult { case written, unconfirmed, deferred, failed(String) }
@MainActor final class WallpaperService {
    static let shared = WallpaperService()
    var writes = 0
    var sharedPicture = false
    var unconfirmed = false
    var rejected = false
    var pictures: [UInt64: String] = [1: "/original.png", 2: "/original.png"]
    var canPreloadSpaces: Bool { true }
    func showOnAllSpaces() -> Bool? { sharedPicture }
    func displayID(of screen: NSScreen) -> CGDirectDisplayID? { CGMainDisplayID() }
    func displayUUID(of screen: NSScreen) -> String? { "TEST-DISPLAY" }
    func isShowing(spaceID: UInt64?, on screen: NSScreen) -> Bool { true }
    func readSlot(displayID: CGDirectDisplayID, spaceUUID: String?, spaceID: UInt64? = nil, screen: NSScreen?, isVisible: Bool) -> SlotPicture? {
        SlotPicture(path: pictures[spaceID ?? 1] ?? "/original.png", placement: .fill, fillColor: .black)
    }
    func shows(_ a: SlotPicture, _ b: SlotPicture) -> Bool { a.path == b.path }
    func isImageFile(_ url: URL) -> Bool { true }
    func stillImage(standingInFor path: String) -> URL? { nil }
    func isSystemPlaceholder(_ url: URL) -> Bool { false }
    func isUnchanged(source: String, copy: String) -> Bool { true }
    func writeSlot(_ picture: SlotPicture, displayID: CGDirectDisplayID, spaceUUID: String?, spaceID: UInt64?, screen: NSScreen?, isVisible: Bool) async -> SlotWriteResult {
        writes += 1
        if rejected { return .failed("Rejected before changing anything") }
        if unconfirmed { return .unconfirmed }
        // Simulate macOS replacing the global wallpaper before it creates per-Space records.
        if sharedPicture && writes == 1 { pictures = pictures.mapValues { _ in picture.path } }
        else { pictures[spaceID ?? 1] = picture.path }
        return .written
    }
}
@main struct WallpaperSyncTests {
    @MainActor static func main() async {
        precondition(!NSScreen.screens.isEmpty, "This test needs a logged-in Mac desktop")
        let one = SpaceDescriptor(managedID: 1, uuid: "", type: 0, displayIdentifier: "Main", desktopNumber: 1, fullscreenPID: nil)
        let two = SpaceDescriptor(managedID: 2, uuid: "SECOND", type: 0, displayIdentifier: "Main", desktopNumber: 2, fullscreenPID: nil)
        let snapshot = SpacesSnapshot(activeDisplayIdentifier: "Main", current: one, currentByDisplay: ["Main": 1], spaces: [one, two], isAnimating: false)
        let desired = WallpaperChoice(fileName: "desired.png", displayName: "Desired")
        let service = WallpaperService.shared
        service.unconfirmed = true
        _ = await WallpaperSync.shared.sync(snapshot: snapshot) { _ in desired }
        precondition(WallpaperSync.shared.needsRecheck, "A newly issued unconfirmed write must request verification")
        _ = await WallpaperSync.shared.sync(snapshot: snapshot) { _ in desired }
        precondition(!WallpaperSync.shared.needsRecheck, "The delayed check must not schedule endless checks")
        Store.shared.wallpaperSlots = [:]
        service.unconfirmed = false
        service.sharedPicture = true
        service.writes = 0
        service.pictures = [1: "/original.png", 2: "/original.png"]
        _ = await WallpaperSync.shared.sync(snapshot: snapshot) { _ in desired }
        precondition(Store.shared.wallpaperSlots.count == 2)
        for slot in Store.shared.wallpaperSlots.values {
            precondition(slot.baseline?.sourcePath == "/original.png", "Every baseline must precede the global write")
        }
        Store.shared.wallpaperSlots = [:]
        service.sharedPicture = false
        service.rejected = true
        service.writes = 0
        service.pictures = [1: "/original.png", 2: "/original.png"]
        _ = await WallpaperSync.shared.sync(snapshot: snapshot) { _ in desired }
        precondition(Store.shared.wallpaperSlots.isEmpty, "Rejected writes must discard unused ownership")
        service.pictures = [1: "/user-choice.png", 2: "/user-choice.png"]
        _ = await WallpaperSync.shared.sync(snapshot: snapshot) { _ in nil }
        precondition(service.pictures.values.allSatisfy { $0 == "/user-choice.png" }, "A rejected write must not own a later user choice")
        service.rejected = false
        service.sharedPicture = true
        service.writes = 0
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! Data("Mock original".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        service.pictures = [1: original.path, 2: original.path]
        _ = await WallpaperSync.shared.sync(snapshot: snapshot) { key in key == "SECOND" ? desired : nil }
        precondition(service.pictures[1] == original.path, "Restore an unassigned visible slot after the hidden slot changes the global wallpaper")
        precondition(service.pictures[2] == "/tmp/desired.png")
        precondition(Store.shared.wallpaperSlots.count == 1)
        print("5 wallpaper regression checks passed; no desktop settings changed")
    }
}
