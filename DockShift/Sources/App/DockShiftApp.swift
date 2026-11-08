import AppKit

@main
struct DockShiftMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
enum AppActivation {
    static var openMainWindow: (() -> Void)?
    static func prepareToShowWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func showMainWindow() { prepareToShowWindow(); openMainWindow?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A disposable preview must never fall back to the installed app's data when opened
        // directly by Finder or LaunchServices, which do not inherit the launch script's env.
        if Bundle.main.bundleIdentifier == "com.quentinsteinke.DockShift.RunePreview",
           ProcessInfo.processInfo.environment["DOCKSHIFT_TEST_DATA_DIRECTORY"]?.hasPrefix("/") != true {
            let alert = NSAlert()
            alert.messageText = "Launch the Rune preview from its script"
            alert.informativeText = "Run scripts/run-rune-preview.sh in the DockShift project to open a paused copy with sample profiles."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        Engine.shared.start()
        UpdateService.shared.start()
        AppActivation.openMainWindow = { [weak self] in self?.showMainWindow() }
        setupMenus()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockShift")
        item.button?.target = self; item.button?.action = #selector(toggleMenu(_:))
        statusItem = item
        if Store.shared.isFirstRun || Store.shared.configWarning != nil || ProcessInfo.processInfo.arguments.contains("--show-window") { showMainWindow() }
    }

    func showMainWindow() {
        popover?.close()
        AppActivation.prepareToShowWindow()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "DockShift"
            window.minSize = NSSize(width: 1000, height: 640)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = RuneHost(bridge: makeBridge(menu: false))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleMenu(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true { popover?.close(); return }
        if popover == nil {
            let p = NSPopover(); p.behavior = .transient
            let vc = NSViewController(); vc.view = RuneHost(bridge: makeBridge(menu: true))
            p.contentViewController = vc; popover = p
        }
        popover?.contentSize = NSSize(width: 355, height: min(620, (NSScreen.main?.visibleFrame.height ?? 800) - 60))
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makeBridge(menu: Bool) -> RuneBridge {
        let bridge = RuneBridge(); bridge.isMenu = menu
        bridge.shellAction = { [weak self] action in
            if action == "quit" { NSApp.terminate(nil) } else { self?.showMainWindow() }
        }
        return bridge
    }

    func windowWillClose(_ notification: Notification) {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        DispatchQueue.main.async {
            let visibleWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
            if !visibleWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc private func openWindow(_ sender: Any?) { showMainWindow() }
    @objc private func checkUpdates(_ sender: Any?) { UpdateService.shared.checkForUpdates() }

    private func setupMenus() {
        let menu = NSMenu()
        let app = NSMenu(); let item = NSMenuItem(); item.submenu = app; menu.addItem(item)
        let open = app.addItem(withTitle: "Open DockShift", action: #selector(openWindow(_:)), keyEquivalent: ","); open.target = self
        let quick = app.addItem(withTitle: "Quick controls", action: #selector(toggleMenu(_:)), keyEquivalent: ""); quick.target = self
        let update = app.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates(_:)), keyEquivalent: ""); update.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide DockShift", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit DockShift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit"); let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key) }
        NSApp.mainMenu = menu
    }
}
