// UIHelpers.swift — DockShift
// Wording shared by the menu and the main window, so both describe state the
// same way.
import AppKit
import ImageIO

// MARK: - Wording

@MainActor
enum UIText {
    static func focusSource(_ source: FocusSource) -> String {
        switch source {
        case .none: return "none"
        case .filter: return "Focus filter"
        case .shortcuts: return "Shortcuts"
        case .manual: return "chosen manually"
        }
    }

    /// Manual and Shortcuts choices stick until the next Focus-filter change, so both need a way
    /// out in DockShift; nil when the source has nothing to clear.
    static func clearFocusTitle(_ source: FocusSource) -> String? {
        switch source {
        case .manual: return "Clear Manual Choice"
        case .shortcuts: return "Clear Profile Set by Shortcuts"
        case .none, .filter: return nil
        }
    }

    /// Why a sticky Focus-layer choice is in effect; nil for filter / none.
    static func focusChoiceNote(_ source: FocusSource) -> String? {
        switch source {
        case .manual: return "Chosen in DockShift; it stays until the next Focus change."
        case .shortcuts: return "Set by a Shortcuts automation; it stays until the next Focus change."
        case .none, .filter: return nil
        }
    }

    /// "Work (Focus filter)" or nil when no Focus profile is active.
    static func focusSummary(engine: Engine) -> String? {
        guard let id = engine.focusProfileID else { return nil }
        return "\(engine.profileName(id)) (\(focusSource(engine.focusSource)))"
    }

    static func desktopSummary(engine: Engine) -> String {
        guard engine.spacesAvailable else { return "unavailable" }
        guard let desktop = engine.currentDesktop else { return "unknown" }
        return engine.isOnFullscreenSpace ? "\(desktop.label) (full-screen app showing)" : desktop.label
    }

    /// "Work · Focus", or a plain explanation when nothing manages the channel.
    static func channel(_ channel: ChannelResolution?, engine: Engine) -> String {
        guard let channel, channel.profileID != nil else { return "left as it is" }
        let name = channel.profileID.flatMap { Store.shared.profile($0)?.name } ?? engine.profileName(channel.profileID)
        return "\(name) · \(engine.describe(channel.source))"
    }

    /// Text + SF Symbol for a Dock activity worth showing; nil when idle.
    static func activity(_ activity: DockActivity) -> (text: String, symbol: String, isProblem: Bool)? {
        switch activity {
        case .idle: return nil
        case .paused: return ("Paused — nothing changes automatically", "pause.circle", false)
        case .waiting(let text): return (text, "hourglass", false)
        case .applying(let name): return ("Switching the Dock to “\(name)”…", "arrow.triangle.2.circlepath", false)
        case .failed(let message): return ("Dock change failed: \(message)", "exclamationmark.triangle.fill", true)
        case .throttled: return ("Dock changes on hold: too many Dock restarts in a minute", "exclamationmark.triangle.fill", true)
        }
    }

    /// Menu items grow to fit their title; keep long error text from making the menu huge. Engine
    /// reports can span lines (e.g. Restore Original's), which a menu item shouldn't.
    static func short(_ text: String, limit: Int = 70) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }

    static func contents(of profile: Profile) -> String {
        switch (profile.hasDock, profile.wallpaper != nil) {
        case (true, true): return "Dock and wallpaper"
        case (true, false): return "Dock only"
        case (false, true): return "Wallpaper only"
        case (false, false): return profile.isDefault ? "Empty" : "Empty — inherits everything"
        }
    }

    static let restoreTitle = "Restore your original Dock and wallpaper?"
    static let restoreMessage = """
        DockShift puts back the Dock it saved the first time it ran and every wallpaper it \
        replaced, then pauses itself so nothing changes them again. Your profiles and rules are \
        kept. If you used “Show on all Spaces”, turn it back on in System Settings › Wallpaper.
        """
}

// MARK: - System links

@MainActor
enum SystemLinks {
    static func openFocusSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Selects the file in Finder, or opens its folder when the file has been moved since.
    static func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func openApp(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

// MARK: - Native alerts

@MainActor
enum Alerts {
    /// Runs a modal NSAlert in front of other apps. Returns true when the user confirmed.
    static func confirm(_ title: String, message: String, confirmTitle: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)   // accessory app: otherwise the alert opens behind
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func show(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
