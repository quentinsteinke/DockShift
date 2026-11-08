import AppKit
import UniformTypeIdentifiers

/// The renderer receives value snapshots and emits commands. It never writes DockShift's files
/// or calls a Dock/wallpaper API. Every mutation still goes through Store and Engine on MainActor.
@MainActor
final class RuneBridge: NSObject {
    var isMenu = false
    var shellAction: ((String) -> Void)?
    private let store = Store.shared
    private let engine = Engine.shared
    private var colorProfile: ProfileID?
    private var wallpaperPaths: [String: String] = [:]
    private var wallpaperRefresh = Date.distantPast

    func snapshot() -> String {
        // Reading the wallpaper database on every animation frame would be expensive. Refresh
        // on the host's slow model tick, and retain these paths between ticks.
        if Date().timeIntervalSince(wallpaperRefresh) > 3 {
            wallpaperRefresh = Date()
            for desktop in engine.desktops {
                let screens = WallpaperService.shared.screens(forDisplayIdentifier: desktop.displayIdentifier)
                if let screen = screens.first, let display = WallpaperService.shared.displayID(of: screen),
                   let picture = WallpaperService.shared.readSlot(displayID: display, spaceUUID: desktop.uuid,
                       spaceID: desktop.managedID, screen: screen, isVisible: desktop.ruleKey == engine.currentDesktop?.ruleKey) {
                    wallpaperPaths[desktop.ruleKey] = picture.path
                }
            }
        }
        let profiles: [[String: Any]] = store.profiles.map { p in
            let tiles = store.dockSnapshot(for: p.id).map { DockService.shared.tiles(of: $0) } ?? []
            return ["id": p.id.uuidString, "name": p.name, "isDefault": p.isDefault, "hasDock": p.hasDock,
                    "wallpaperPath": p.wallpaper.map { store.fileURL(for: $0).path } ?? "",
                    "previewPath": p.wallpaper.map { store.fileURL(for: $0).path } ?? wallpaperPaths[engine.currentDesktop?.ruleKey ?? ""] ?? "",
                    "wallpaperName": p.wallpaper?.displayName ?? "", "placement": p.wallpaper?.placement.rawValue ?? "Crop",
                    "fillColor": [p.wallpaper?.fillColor.red ?? 0, p.wallpaper?.fillColor.green ?? 0, p.wallpaper?.fillColor.blue ?? 0],
                    "tiles": tiles.map { ["id": $0.id, "label": $0.label, "path": $0.path ?? "", "missing": $0.isMissing] as [String: Any] },
                    "unreadable": store.isDockUnreadable(p.id)]
        }
        let desktops: [[String: Any]] = engine.desktops.map { d in
            ["key": d.ruleKey, "label": d.label, "display": d.displayIdentifier == engine.currentDesktop?.displayIdentifier ? "Main display" : "External display",
             "profileId": store.assignment(forSpaceKey: d.ruleKey)?.profileID.uuidString ?? "",
             "current": d.ruleKey == engine.currentDesktop?.ruleKey,
             "wallpaperPath": wallpaperPaths[d.ruleKey] ?? ""]
        }
        let settings = store.settings
        let updates = UpdateService.shared
        let info = Bundle.main.infoDictionary ?? [:]
        let data: [String: Any] = [
            "profiles": profiles, "desktops": desktops,
            "activeProfile": store.runtime.appliedDockOK ? store.runtime.appliedDockProfileID?.uuidString ?? "" : "",
            "explicitProfile": [.manual, .shortcuts].contains(FocusRouter.shared.source) ? FocusRouter.shared.profileID?.uuidString ?? "" : "",
            "focus": UIText.focusSummary(engine: engine) ?? "No Focus profile",
            "focusStatus": FocusRouter.shared.filterStatus, "desktop": UIText.desktopSummary(engine: engine),
            "activity": UIText.activity(engine.dockActivity)?.text ?? "", "error": engine.lastError ?? store.lastError ?? "",
            "warnings": store.warnings.map(\.text), "paused": settings.paused, "canResume": engine.canResume,
            "rememberEdits": settings.rememberDockEdits, "desktopDock": settings.switchDockPerDesktop,
            "dwell": settings.desktopDockDwell, "dockPrecedence": settings.dockPrecedence.rawValue,
            "wallpaperPrecedence": settings.wallpaperPrecedence.rawValue,
            "login": LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval,
            "loginAvailable": LaunchAtLogin.isInstalledInApplications, "loginApproval": LaunchAtLogin.needsApproval,
            "automaticUpdates": updates.automaticallyChecksForUpdates, "canUpdate": updates.canCheckForUpdates,
            "updateProblem": updates.configurationProblem ?? "", "version": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "spacesAvailable": engine.spacesAvailable,
            "appearance": UserDefaults.standard.object(forKey: "rune.dark") ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua),
            "dockStatus": UIText.channel(engine.resolution?.dock, engine: engine),
            "wallpaperStatus": UIText.channel(engine.resolution?.wallpaper, engine: engine),
            "restarts": DockService.shared.restartLog.filter { $0 > Date().addingTimeInterval(-3600) }.count,
            "menu": isMenu, "reducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              let string = String(data: bytes, encoding: .utf8) else { return "{}" }
        return string
    }

    /// Returns a new profile ID when the renderer should navigate into the profile it created.
    func perform(_ command: [String: Any]) -> String? {
        guard let action = command["action"] as? String else { return nil }
        let id = (command["id"] as? String).flatMap(UUID.init(uuidString:))
        let value = command["value"]
        do {
            switch action {
            case "use": if let id, store.profile(id) != nil { engine.applyManually(profileID: id) }
            case "stop": engine.applyManually(profileID: nil)
            case "pause": if let on = value as? Bool, !on ? engine.canResume : true { engine.setPaused(on) }
            case "create":
                guard let object = value as? [String: Any], let name = object["name"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let p: Profile
                if object["capture"] as? Bool == true {
                    let created = try engine.createProfileFromCurrentSetup(name: name)
                    p = created.profile
                    if let note = created.note {
                        let alert = NSAlert()
                        alert.messageText = "Profile created"
                        alert.informativeText = note
                        alert.runModal()
                    }
                }
                else { p = store.createProfile(name: name, isDefault: false) }
                return p.id.uuidString
            case "rename": if let id, let name = value as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.renameProfile(id, to: name) }
            case "delete": if let id, store.profile(id)?.isDefault == false { engine.deleteProfile(id) }
            case "captureDock":
                if let id, confirmCapture(id) { try engine.captureCurrentDock(into: id) }
            case "clearDock":
                if let id, Alerts.confirm("Inherit this profile’s Dock?", message: "Its saved Dock will be removed. It will use the next rule’s Dock instead.", confirmTitle: "Inherit Dock") { store.setDockSnapshot(nil, for: id) }
            case "captureWallpaper": if let id { try engine.captureCurrentWallpaper(into: id) }
            case "clearWallpaper": if let id { store.setWallpaper(nil, for: id) }
            case "chooseWallpaper": if let id { try chooseWallpaper(id) }
            case "placement":
                if let id, var wallpaper = store.profile(id)?.wallpaper, let raw = value as? String, let placement = Placement(rawValue: raw) {
                    wallpaper.placement = placement; store.setWallpaper(wallpaper, for: id)
                }
            case "fillColor": if let id, let wallpaper = store.profile(id)?.wallpaper {
                colorProfile = id
                let panel = NSColorPanel.shared
                panel.color = NSColor(srgbRed: wallpaper.fillColor.red, green: wallpaper.fillColor.green, blue: wallpaper.fillColor.blue, alpha: 1)
                panel.showsAlpha = false; panel.setTarget(self); panel.setAction(#selector(colorChanged(_:))); panel.makeKeyAndOrderFront(nil)
            }
            case "addApp": if let id { try addApps(id) }
            case "removeTile": if let id, let index = value as? Int { try editTile(id, index: index, offset: nil) }
            case "moveTile":
                if let id, let object = value as? [String: Int], let index = object["index"], let offset = object["offset"] { try editTile(id, index: index, offset: offset) }
            case "assign":
                guard let key = command["id"] as? String, let d = engine.desktops.first(where: { $0.ruleKey == key }) else { break }
                let profile = (value as? String).flatMap(UUID.init(uuidString:))
                guard profile == nil || store.profile(profile) != nil else { break }
                store.setAssignment(profileID: profile, spaceKey: key, displayIdentifier: d.displayIdentifier, label: d.label)
            case "rememberEdits": if let on = value as? Bool { store.updateSettings { $0.rememberDockEdits = on } }
            case "desktopDock": if let on = value as? Bool { store.updateSettings { $0.switchDockPerDesktop = on } }
            case "dwell": if let n = value as? Double { store.updateSettings { $0.desktopDockDwell = min(5, max(0.4, n)) } }
            case "dockPrecedence": if let raw = value as? String, let p = Precedence(rawValue: raw) { store.updateSettings { $0.dockPrecedence = p } }
            case "wallpaperPrecedence": if let raw = value as? String, let p = Precedence(rawValue: raw) { store.updateSettings { $0.wallpaperPrecedence = p } }
            case "login": if LaunchAtLogin.isInstalledInApplications, let on = value as? Bool { try LaunchAtLogin.set(on) }
            case "loginSettings": LaunchAtLogin.openSystemSettings()
            case "autoUpdates": if let on = value as? Bool { UpdateService.shared.setAutomaticChecks(on) }
            case "checkUpdates": UpdateService.shared.checkForUpdates()
            case "restore": Task { await engine.restoreOriginal() }
            case "confirmRestore":
                if Alerts.confirm(UIText.restoreTitle, message: UIText.restoreMessage, confirmTitle: "Restore") { Task { await engine.restoreOriginal() } }
            case "retry": engine.retryDock()
            case "resetThrottle": engine.resetThrottle()
            case "showData": SystemLinks.reveal(store.baseDirectory)
            case "logs": SystemLinks.openApp(bundleIdentifier: "com.apple.Console")
            case "focusSettings": SystemLinks.openFocusSettings()
            case "checkFocus": FocusRouter.shared.reconcile(reason: "manual")
            case "missionControl": SystemLinks.openApp(bundleIdentifier: "com.apple.exposelauncher")
            case "shortcuts": SystemLinks.openApp(bundleIdentifier: "com.apple.shortcuts")
            case "revealWarning": if let file = store.warnings.first?.file { SystemLinks.reveal(file) }
            case "dismissWarning": if let warning = store.warnings.first, warning.isDismissible { store.dismissWarning(warning.kind) }
            case "appearance": UserDefaults.standard.set(value as? Bool ?? false, forKey: "rune.dark")
            case "openMain", "quit": shellAction?(action)
            default: break
            }
        } catch { Alerts.show("DockShift couldn’t complete that change", error: error) }
        return nil
    }

    private func confirmCapture(_ id: ProfileID) -> Bool {
        guard let profile = store.profile(id), profile.hasDock else { return true }
        let runtime = store.runtime
        if runtime.appliedDockOK && runtime.appliedDockProfileID == id && engine.dockActivity == .idle && !store.settings.paused { return true }
        return Alerts.confirm("Replace the saved Dock in \(profile.name)?", message: "The Dock on screen may belong to a different profile. Capture replaces this profile’s saved apps and folders.", confirmTitle: "Capture Dock")
    }

    private func chooseWallpaper(_ id: ProfileID) throws {
        guard let p = store.profile(id) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.message = "Choose a wallpaper for \(p.name). DockShift keeps its own copy."; panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let wallpaper = try store.ingestWallpaper(from: url, placement: p.wallpaper?.placement ?? .fill, fillColor: p.wallpaper?.fillColor ?? .black)
        store.setWallpaper(wallpaper, for: id)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let id = colorProfile, var wallpaper = store.profile(id)?.wallpaper,
              let color = sender.color.usingColorSpace(.sRGB) else { return }
        wallpaper.fillColor = RGBColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        store.setWallpaper(wallpaper, for: id)
    }

    private func addApps(_ id: ProfileID) throws {
        guard store.profile(id) != nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications"); panel.prompt = "Add to Dock"
        guard panel.runModal() == .OK else { return }
        var snapshot = try store.dockSnapshot(for: id) ?? emptySnapshot()
        var apps = try PropertyListSerialization.propertyList(from: snapshot.persistentApps, format: nil) as? [[String: Any]] ?? []
        for url in panel.urls {
            let tile: [String: Any] = ["tile-type": "file-tile", "tile-data": [
                "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15],
                "file-label": url.deletingPathExtension().lastPathComponent,
                "bundle-identifier": Bundle(url: url)?.bundleIdentifier ?? "", "file-type": 41] as [String: Any]]
            apps.append(tile)
        }
        snapshot.persistentApps = try PropertyListSerialization.data(fromPropertyList: apps, format: .binary, options: 0)
        snapshot.capturedAt = Date(); store.setDockSnapshot(snapshot, for: id)
    }

    private func emptySnapshot() throws -> DockSnapshot {
        let empty = try PropertyListSerialization.data(fromPropertyList: [[String: Any]](), format: .binary, options: 0)
        return DockSnapshot(persistentApps: empty, persistentOthers: empty, capturedAt: Date(), osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    /// Keep the two Dock sections separate. App tiles cannot cross into files/folders, and
    /// untouched dictionaries preserve bookmarks, spacer types, URL tiles and binary values.
    private func editTile(_ id: ProfileID, index: Int, offset: Int?) throws {
        guard var snapshot = store.dockSnapshot(for: id) else { return }
        var apps = try PropertyListSerialization.propertyList(from: snapshot.persistentApps, format: nil) as? [[String: Any]] ?? []
        var others = try PropertyListSerialization.propertyList(from: snapshot.persistentOthers, format: nil) as? [[String: Any]] ?? []
        guard index >= 0, index < apps.count + others.count else { return }
        func mutate(_ tiles: inout [[String: Any]], _ i: Int) {
            if let offset {
                let j = i + offset
                guard tiles.indices.contains(j) else { return }; tiles.swapAt(i, j)
            } else { tiles.remove(at: i) }
        }
        if index < apps.count { mutate(&apps, index) } else { mutate(&others, index - apps.count) }
        snapshot.persistentApps = try PropertyListSerialization.data(fromPropertyList: apps, format: .binary, options: 0)
        snapshot.persistentOthers = try PropertyListSerialization.data(fromPropertyList: others, format: .binary, options: 0)
        snapshot.capturedAt = Date(); store.setDockSnapshot(snapshot, for: id)
    }
}
