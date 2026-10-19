// UIHelpers.swift — DockShift
// Small views and wording shared by the menu and the main window, so both describe state the
// same way.
import SwiftUI
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
        return "\(engine.profileName(channel.profileID)) · \(engine.describe(channel.source))"
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

// MARK: - Alerts (for the menu, which can't host SwiftUI dialogs)

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

// MARK: - Store warnings

/// "Show in Finder" / "Dismiss" for a problem DockShift found in its own files; shared by the
/// status banner, Get Started and Settings.
struct StoreWarningButtons: View {
    let warning: StoreWarning

    var body: some View {
        if let file = warning.file {
            Button("Show in Finder") { SystemLinks.reveal(file) }
                .help(file.lastPathComponent)
        }
        if warning.isDismissible {
            Button("Dismiss") { Store.shared.dismissWarning(warning.kind) }
        }
    }
}

// MARK: - Step row (onboarding / setup instructions)

struct StepRow<Accessory: View>: View {
    let number: Int
    let title: String
    let detail: String
    var done = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
                } else {
                    Image(systemName: "\(number).circle").foregroundStyle(.tint)
                }
            }
            .font(.title2)
            .frame(width: 26)
            .accessibilityLabel(done ? "Step \(number), done" : "Step \(number)")

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

extension StepRow where Accessory == EmptyView {
    init(number: Int, title: String, detail: String, done: Bool = false) {
        self.init(number: number, title: title, detail: detail, done: done) { EmptyView() }
    }
}

/// Small rounded "Current" style tag.
struct TagText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}

// MARK: - Wallpaper thumbnail

/// Aspect-fill 16:10 preview of an image file. Decoding a full-size wallpaper (often a 6K HEIC)
/// on the main thread would stall the window, so a downsampled thumbnail is made off the main actor.
struct WallpaperThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .background(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if url == nil || failed {
                    Image(systemName: url == nil ? "photo" : "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .task(id: url) {
                image = nil
                failed = false
                guard let url else { return }
                let thumb = await Task.detached(priority: .userInitiated) { Thumbnail.make(url, maxPixel: 800) }.value
                guard !Task.isCancelled else { return }
                if let cg = thumb?.image {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                } else {
                    failed = true
                }
            }
    }
}

private struct Thumbnail: @unchecked Sendable {   // CGImage is immutable; safe to hand across actors
    let image: CGImage

    static func make(_ url: URL, maxPixel: Int) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Thumbnail(image: image)
    }
}

// MARK: - Color bridging

/// Namespaced (not an extension on the shared RGBColor) so it can't collide with other files.
enum ColorBridge {
    static func rgb(_ color: Color) -> RGBColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return RGBColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }

    static func color(_ rgb: RGBColor) -> Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue) }
}
