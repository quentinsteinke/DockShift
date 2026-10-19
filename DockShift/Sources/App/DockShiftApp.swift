// DockShiftApp.swift — DockShift
// Scenes, app delegate and activation handling. DockShift is an LSUIElement (menu-bar) app: the
// menu is always there, the main window only exists while the user has it open.
import SwiftUI
import AppKit

@main
struct DockShiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        // Opened on demand from the menu; never at launch, never restored. Settings live in the
        // sidebar instead of a Settings scene, which is unreliable from a MenuBarExtra.
        Window("DockShift", id: "main") {
            MainWindow()
                .onDisappear { AppActivation.windowDidClose() }
        }
        .defaultSize(width: 860, height: 600)
        .defaultLaunchBehavior(.suppressed)   // macOS 15+
        .restorationBehavior(.disabled)       // macOS 15+
        .handlesExternalEvents(matching: [])  // an intent / user activity must never spawn or raise it
    }
}

/// The status-item icon. It is the only view alive from launch on, so it also owns the
/// "open the window on first run" step and hands out `openWindow` to non-view code.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    private let store = Store.shared

    var body: some View {
        Image(systemName: store.settings.paused ? "pause.rectangle" : "dock.rectangle")
            .accessibilityLabel(store.settings.paused ? "DockShift (paused)" : "DockShift")
            .task { await launchTasks() }
    }

    private func launchTasks() async {
        let open = openWindow
        AppActivation.openMainWindow = { open(id: "main") }
        guard !AppActivation.didHandleFirstRun else { return }
        AppActivation.didHandleFirstRun = true
        // Engine.start() runs from applicationDidFinishLaunching; isFirstRun is only meaningful after it.
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<20 where !Engine.shared.started {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // A settings file that had to be set aside is shown like a first run, with the notice on top.
        if Store.shared.isFirstRun || Store.shared.configWarning != nil { AppActivation.showMainWindow() }
    }
}

/// LSUIElement apps are "accessory" apps: their windows open *behind* the frontmost app and
/// `NSApp.activate()` alone is refused. Become a regular app while a window is up, then drop back.
@MainActor
enum AppActivation {
    /// Set by `MenuBarLabel`; lets the app delegate open the window (e.g. on relaunch from Finder).
    static var openMainWindow: (@MainActor () -> Void)?
    static var didHandleFirstRun = false

    static func prepareToShowWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()                                  // macOS 14+
        // Fallback: activate() is "cooperative" and can be refused for accessory apps.
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showMainWindow() {
        prepareToShowWindow()
        openMainWindow?()
    }

    static func windowDidClose() {
        // The shared Colors panel outlives the colour well that opened it; it has nothing to edit
        // once the window is gone. (Checking first avoids creating the panel just to close it.)
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        // Defer so SwiftUI finishes tearing the window down first. Panels (Colors, open panels,
        // alerts) never keep DockShift a regular app: nothing re-checks when they close.
        DispatchQueue.main.async {
            let anyVisible = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
            }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Engine.shared.start()
    }

    /// Launching DockShift again while it runs (Finder, Spotlight) opens the window — the only way
    /// back in when the menu-bar icon is hidden behind the notch or a crowded menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppActivation.showMainWindow() }
        return true
    }
}
