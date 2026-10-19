// SettingsView.swift — DockShift
// App-wide options, the exit path (restore original) and troubleshooting helpers.
import SwiftUI
import AppKit

struct SettingsView: View {
    private let store = Store.shared
    private let engine = Engine.shared
    @State private var confirmRestore = false
    @State private var showLogHelp = false

    var body: some View {
        Form {
            Section("General") {
                LaunchAtLoginControl()
                Toggle(isOn: Binding(get: { store.settings.paused }, set: { engine.setPaused($0) })) {
                    Text("Pause DockShift")
                    Text(store.settings.paused && !engine.canResume
                         ? "DockShift stays paused until it can read its settings file again."
                         : "While paused, DockShift doesn’t change your Dock or wallpaper.")
                }
                // Resuming on the empty stand-in rules would undo the user's setup (Engine.canResume).
                .disabled(store.settings.paused && !engine.canResume)
            }

            Section {
                Picker(selection: precedenceBinding(\.dockPrecedence)) {
                    ForEach(Precedence.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Dock")
                    Text("When a Focus and the current desktop both pick a profile")
                }
                Picker(selection: precedenceBinding(\.wallpaperPrecedence)) {
                    ForEach(Precedence.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Wallpaper")
                    Text("When a Focus and the current desktop both pick a profile")
                }
            } header: {
                Text("When Rules Overlap")
            } footer: {
                Text("Anything the winning profile leaves empty comes from the other rule, then from Default.")
                    .foregroundStyle(.secondary)
            }

            Section("Dock") {
                Toggle(isOn: settingBinding(\.rememberDockEdits)) {
                    Text("Remember manual Dock edits")
                    Text("If you add, remove or move items while a profile’s Dock is showing, save that into the profile before switching away.")
                }
                if let key = DockService.shared.managedKey() {
                    Label(String("Your organization manages the Dock (\(key)), so DockShift can’t change it."),
                          systemImage: "lock.fill")
                }
            }

            Section {
                LabeledContent {
                    Button("Restore…") { confirmRestore = true }
                        .disabled(!store.hasOriginal && store.wallpaperSlots.isEmpty)
                } label: {
                    Text("Restore Original Dock & Wallpaper")
                    Text("Puts back your original Dock and every wallpaper DockShift replaced, and pauses DockShift.")
                }
            } header: {
                Text("Restore")
            }

            troubleshootingSection

            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(UIText.restoreTitle, isPresented: $confirmRestore) {
            Button("Restore") { Task { await engine.restoreOriginal() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(UIText.restoreMessage)
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            LabeledContent("Dock restarts in the last hour") {
                Text("\(restartsLastHour)").monospacedDigit()
            }
            if let date = engine.lastDockApply {
                LabeledContent("Last Dock change", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if engine.dockActivity == .throttled {
                LabeledContent {
                    Button("Reset Throttle") { engine.resetThrottle() }
                } label: {
                    Text("Dock changes are on hold")
                    Text("DockShift stops after too many Dock restarts in a minute, to avoid a restart loop.")
                }
            }
            if let error = store.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            ForEach(store.warnings) { warning in
                LabeledContent {
                    HStack { StoreWarningButtons(warning: warning) }
                } label: {
                    Label {
                        Text(verbatim: warning.text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
            }
            HStack {
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.baseDirectory])
                }
                .help("Profiles, saved Docks and wallpaper copies live here")
                Button("Show Logs…") { showLogHelp = true }
                    .popover(isPresented: $showLogHelp, arrowEdge: .bottom) { LogHelp() }
            }
        }
    }

    private var restartsLastHour: Int {
        let cutoff = Date().addingTimeInterval(-3600)
        return DockService.shared.restartLog.filter { $0 > cutoff }.count
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Bindings

    private func settingBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private func precedenceBinding(_ keyPath: WritableKeyPath<AppSettings, Precedence>) -> Binding<Precedence> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Log help

/// Explains how to read DockShift's unified log (there is no in-app log viewer).
private struct LogHelp: View {
    private var streamCommand: String {
        "log stream --level debug --predicate 'subsystem == \"\(Log.subsystem)\"'"
    }
    private var showCommand: String {
        "log show --last 1h --info --debug --predicate 'subsystem == \"\(Log.subsystem)\"'"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DockShift writes everything it decides and does to the system log.")
                .fixedSize(horizontal: false, vertical: true)
            command("To watch it live, run this in Terminal:", streamCommand)
            command("To see the last hour:", showCommand)
            HStack {
                Spacer()
                Button("Open Console") { SystemLinks.openApp(bundleIdentifier: "com.apple.Console") }
            }
            Text(verbatim: "In Console, search for “subsystem:\(Log.subsystem)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 460)
    }

    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(verbatim: text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityLabel("Copy command")
            }
            .padding(8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Launch at login

/// Shared by Settings and the Focus page (DockShift must run to receive Focus changes).
/// SMAppService state is re-read whenever the app becomes active, because approval happens in
/// System Settings, outside DockShift.
struct LaunchAtLoginControl: View {
    @State private var isEnabled = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var errorText: String?

    var body: some View {
        // Registered-but-unapproved shows as on: that is what the user asked for, and the row
        // below says what is missing. Showing it off invites a toggle that can't succeed.
        Toggle(isOn: Binding(get: { isEnabled || needsApproval }, set: { set($0) })) {
            Text("Open DockShift at login")
            if !LaunchAtLogin.isInstalledInApplications {
                Text("Move DockShift to the Applications folder to turn this on.")
            }
        }
        .disabled(!LaunchAtLogin.isInstalledInApplications)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }

        if needsApproval {
            LabeledContent {
                Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
            } label: {
                Text("Waiting for your approval")
                Text("Allow DockShift in System Settings › General › Login Items.")
            }
        }
        if let errorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }

    /// While approval is pending, or when register() reports it needs approval, LaunchAtLogin
    /// opens Login Items itself (only the user can allow it there).
    private func set(_ on: Bool) {
        defer { refresh() }
        do {
            try LaunchAtLogin.set(on)
            errorText = nil
        } catch LaunchAtLogin.Failure.needsApproval {
            errorText = "macOS needs your approval: allow DockShift in System Settings › General › Login Items."
        } catch {
            errorText = "Couldn’t change the login item: \(error.localizedDescription)"
        }
    }

    private func refresh() {
        isEnabled = LaunchAtLogin.isEnabled
        needsApproval = LaunchAtLogin.needsApproval
        if needsApproval || isEnabled { errorText = nil }   // the approval row says it better
    }
}
