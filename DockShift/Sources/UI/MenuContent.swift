// MenuContent.swift — DockShift
// The menu-bar menu (`.menu` style: plain Buttons/Toggles/Menus/Text). Disabled Text rows show
// what DockShift is doing right now; actions cover the quick things people do without the window.
import SwiftUI
import AppKit

struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    private let engine = Engine.shared
    private let store = Store.shared

    var body: some View {
        statusRows

        Divider()

        Menu("Apply Profile") {
            Text("Overrides the Focus profile until the Focus next changes")
            ForEach(store.profiles) { profile in
                Toggle(profile.name, isOn: manualBinding(for: profile.id))
            }
            if let clear = UIText.clearFocusTitle(engine.focusSource) {
                Divider()
                Button(clear) { engine.applyManually(profileID: nil) }
            }
        }
        saveDockButton

        Divider()

        Toggle("Pause DockShift", isOn: Binding(
            get: { store.settings.paused },
            set: { engine.setPaused($0) }))
            .disabled(store.settings.paused && !engine.canResume)   // settings file unreadable
        if engine.dockActivity == .throttled {
            Button("Reset Throttle") { engine.resetThrottle() }
        }
        // While paused a retry only resets the status (e.g. after Restore Original's Dock failed).
        if case .failed = engine.dockActivity, !store.settings.paused {
            Button("Retry Dock Change") { engine.retryDock() }
        }

        Divider()

        Button("Open DockShift…") {
            AppActivation.prepareToShowWindow()
            openWindow(id: "main")
        }
        .keyboardShortcut(",")
        // The Original holds a Dock only once one was captured; wallpaper slots restore without it.
        Button("Restore Original Dock & Wallpaper…") { confirmRestore() }
            .disabled(!store.hasOriginal && store.wallpaperSlots.isEmpty)

        Divider()

        Button("Quit DockShift") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: Status

    @ViewBuilder private var statusRows: some View {
        Text("Focus: " + (UIText.focusSummary(engine: engine) ?? "none"))
        Text("Desktop: " + UIText.desktopSummary(engine: engine))
        Text("Dock: " + UIText.channel(engine.resolution?.dock, engine: engine))
        Text("Wallpaper: " + UIText.channel(engine.resolution?.wallpaper, engine: engine))
        if let activity = UIText.activity(engine.dockActivity) {
            Text(UIText.short(activity.text))
        }
        if let error = engine.lastError, !isShownByActivity(error) {
            Text("⚠︎ " + UIText.short(error))
        }
        if let problem = store.lastError {
            Text("⚠︎ " + UIText.short(problem))
        }
    }

    /// A failed apply already shows its message in the activity row.
    private func isShownByActivity(_ error: String) -> Bool {
        if case .failed(let message) = engine.dockActivity { return message == error }
        return false
    }

    // MARK: Actions

    @ViewBuilder private var saveDockButton: some View {
        if let owner = engine.resolution?.dock.profileID, let profile = store.profile(owner) {
            Button(String("Save Current Dock to “\(profile.name)”")) {   // String: no Markdown in names
                saveDock(into: profile)
            }
        } else {
            Button("Save Current Dock to Profile") {}
                .disabled(true)
        }
    }

    /// The item names the profile the rules pick, which is not always the Dock on screen (a switch
    /// still waiting or failed, paused, a full-screen Space). Replacing a saved layout with a Dock
    /// that may belong to another profile asks first, like Capture in the window does.
    private func saveDock(into profile: Profile) {
        let rt = store.runtime
        let showsOwnersDock = rt.appliedDockOK && rt.appliedDockProfileID == profile.id
            && engine.dockActivity == .idle && !store.settings.paused
        if profile.hasDock && !showsOwnersDock {
            let message: String
            if rt.appliedDockOK, let shown = store.profile(rt.appliedDockProfileID), shown.id != profile.id {
                message = "The Dock on screen is “\(engine.profileName(shown.id))”’s layout. Saving replaces the layout stored in “\(profile.name)” with it."
            } else {
                message = "DockShift can’t confirm that the Dock on screen is “\(profile.name)”’s layout (a change may be waiting, paused or failed). Saving replaces the layout stored in “\(profile.name)” with whatever is on screen."
            }
            guard Alerts.confirm(String("Replace the saved Dock of “\(profile.name)”?"), message: message,
                                 confirmTitle: "Replace Dock") else { return }
        }
        do { try engine.captureCurrentDock(into: profile.id) }
        catch { Alerts.show("Couldn’t save the Dock", error: error) }
    }

    /// Checked = this profile is the manual Focus-layer choice. Unchecking clears the choice.
    private func manualBinding(for id: ProfileID) -> Binding<Bool> {
        Binding(
            get: { engine.focusSource == .manual && engine.focusProfileID == id },
            set: { on in engine.applyManually(profileID: on ? id : nil) })
    }

    private func confirmRestore() {
        guard Alerts.confirm(UIText.restoreTitle, message: UIText.restoreMessage,
                             confirmTitle: "Restore") else { return }
        Task { await Engine.shared.restoreOriginal() }
    }
}
