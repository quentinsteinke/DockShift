// MainWindow.swift — DockShift
// Sidebar (Get Started, Profiles, Desktops, Focus Modes, Settings) + detail, with a live status
// banner on top of every detail page so the user always sees what DockShift is doing.
import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case getStarted
    case profile(ProfileID)
    case desktops
    case focus
    case settings
}

struct MainWindow: View {
    @State private var selection: SidebarItem? = .getStarted
    @State private var showingNewProfile = false
    private let store = Store.shared
    private let engine = Engine.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) { StatusBanner() }
        }
        .frame(minWidth: 760, minHeight: 500)
        .sheet(isPresented: $showingNewProfile) {
            NewProfileSheet { selection = .profile($0) }
        }
        .onChange(of: store.profiles.map(\.id)) { _, ids in
            // The selected profile was deleted (from the menu, another window, …).
            if case .profile(let id)? = selection, !ids.contains(id) { selection = .getStarted }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Get Started", systemImage: "checklist")
                .tag(SidebarItem.getStarted)

            Section {
                ForEach(store.profiles) { profile in
                    ProfileSidebarRow(profile: profile, inUse: isInUse(profile.id))
                        .tag(SidebarItem.profile(profile.id))
                }
            } header: {
                HStack {
                    Text("Profiles")
                    Spacer()
                    Button { showingNewProfile = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New Profile")
                        .accessibilityLabel("New Profile")
                }
            }

            Section("Rules") {
                Label("Desktops", systemImage: "rectangle.3.group")
                    .tag(SidebarItem.desktops)
                Label("Focus Modes", systemImage: "moon")
                    .tag(SidebarItem.focus)
            }

            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Labeled, always-visible entry point (the header "+" is easy to miss).
            Button { showingNewProfile = true } label: {
                Label("New Profile", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Create a profile from your current Dock and wallpaper")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isInUse(_ id: ProfileID) -> Bool {
        engine.resolution?.dock.profileID == id || engine.resolution?.wallpaper.profileID == id
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .getStarted?:
            GetStartedView(navigate: { selection = $0 }, newProfile: { showingNewProfile = true })
                .navigationTitle("Get Started")
        case .profile(let id)?:
            ProfileDetailView(profileID: id, navigate: { selection = $0 })
                .id(id)   // fresh @State (name field, alerts) per profile
        case .desktops?:
            DesktopsView()
                .navigationTitle("Desktops")
        case .focus?:
            FocusSetupView(newProfile: { showingNewProfile = true })
                .navigationTitle("Focus Modes")
        case .settings?:
            SettingsView()
                .navigationTitle("Settings")
        case nil:
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left",
                                   description: Text("Choose a profile or a section in the sidebar."))
        }
    }
}

// MARK: - Sidebar row

private struct ProfileSidebarRow: View {
    let profile: Profile
    let inUse: Bool

    var body: some View {
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: profile.name)
                    Text(UIText.contents(of: profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if inUse {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .help("Showing now")
                        .accessibilityLabel("Showing now")
                }
            }
        } icon: {
            Image(systemName: profile.isDefault ? "house" : "dock.rectangle")
        }
        .help(profile.isDefault ? "Used whenever no Focus or desktop rule applies" : "")
    }
}

// MARK: - Status banner

/// One line of live state: Focus profile, current desktop, Dock activity; plus a line for
/// errors / pause with the matching fix-it button, and one for problems with DockShift's own files.
private struct StatusBanner: View {
    private let engine = Engine.shared
    private let store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                item(symbol: "moon", title: "Focus",
                     value: UIText.focusSummary(engine: engine) ?? "No Focus profile")
                item(symbol: "menubar.rectangle", title: "Desktop", value: UIText.desktopSummary(engine: engine))
                dockItem
                Spacer(minLength: 0)
            }
            if store.settings.paused {
                notice(symbol: "pause.circle", text: "DockShift is paused. Nothing changes automatically.") {
                    Button("Resume") { engine.setPaused(false) }
                        .disabled(!engine.canResume)    // the settings-file warning below says why
                }
                // E.g. what Restore Original couldn't put back (it pauses DockShift).
                if let error = engine.lastError {
                    notice(symbol: "exclamationmark.triangle.fill", text: error) { dismissButton }
                }
            } else if engine.dockActivity == .throttled {
                notice(symbol: "exclamationmark.triangle.fill", text: engine.lastError ?? "Dock changes are on hold.") {
                    Button("Reset Throttle") { engine.resetThrottle() }
                }
            } else if case .failed(let message) = engine.dockActivity {
                notice(symbol: "exclamationmark.triangle.fill", text: engine.lastError ?? message) {
                    Button("Retry") { engine.retryDock() }
                        .help("Try the Dock change again now")
                }
            } else if let error = engine.lastError {
                notice(symbol: "exclamationmark.triangle.fill", text: error) { dismissButton }
            }
            // Separate line: a Dock error must not hide that a settings file was set aside.
            if let warning = store.warnings.first {
                notice(symbol: "exclamationmark.triangle.fill", text: warning.text) {
                    StoreWarningButtons(warning: warning)
                }
            } else if let error = store.saveError {
                notice(symbol: "exclamationmark.triangle.fill", text: error) { EmptyView() }
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Wallpapers that can never be put back stay listed until the user has seen them.
    @ViewBuilder private var dismissButton: some View {
        if engine.canDismissError {
            Button("Dismiss") { engine.dismissError() }
        }
    }

    @ViewBuilder private var dockItem: some View {
        if let activity = UIText.activity(engine.dockActivity), engine.dockActivity != .paused {
            HStack(spacing: 5) {
                Image(systemName: activity.symbol)
                    .symbolRenderingMode(activity.isProblem ? .multicolor : .monochrome)
                    .foregroundStyle(activity.isProblem ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(activity.text).truncationMode(.tail)
            }
            .help(activity.text)
        } else {
            item(symbol: "dock.rectangle", title: "Dock", value: UIText.channel(engine.resolution?.dock, engine: engine))
        }
    }

    private func item(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: value).truncationMode(.tail)
        }
        .help(title + ": " + value)
    }

    private func notice<B: View>(symbol: String, text: String, @ViewBuilder button: () -> B) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).symbolRenderingMode(.multicolor)
            Text(verbatim: text).lineLimit(2).truncationMode(.tail).help(text)
            Spacer(minLength: 8)
            HStack(spacing: 6) { button() }
                .controlSize(.small)
                .fixedSize()
        }
    }
}
