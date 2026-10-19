// ProfileDetailView.swift — DockShift
// One profile: name, its Dock (preview + capture), its wallpaper (image, placement, fill) and
// where it is used. Every "half" can be empty, which means inherit — the copy says so in place.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfileDetailView: View {
    let profileID: ProfileID
    var navigate: (SidebarItem) -> Void

    private let store = Store.shared
    private let engine = Engine.shared

    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var tiles: [DockTileInfo] = []
    @State private var pendingFill: Color?
    @State private var confirmation: Confirmation?
    @State private var failure: Failure?

    private enum Confirmation: Identifiable {
        case replaceDock, clearDock, clearWallpaper, delete
        var id: Self { self }
    }

    private struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        if let profile = store.profile(profileID) {
            content(profile)
                .navigationTitle(profile.name)
        } else {
            ContentUnavailableView("Profile Not Found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been deleted."))
        }
    }

    private func content(_ profile: Profile) -> some View {
        Form {
            headerSection(profile)
            dockSection(profile)
            wallpaperSection(profile)
            usedBySection(profile)
            if !profile.isDefault {
                Section {
                    Button("Delete Profile…", role: .destructive) { confirmation = .delete }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = profile.name }
        .onDisappear {
            commitName()
            commitFill()   // the debounce below is cancelled with the view
        }
        .task(id: profile.hasDock ? profile.dockRevision : -1) {
            tiles = store.dockSnapshot(for: profileID).map { DockService.shared.tiles(of: $0) } ?? []
        }
        .task(id: pendingFill) {
            // ColorPicker reports every drag step; save (and re-apply) only once it settles.
            guard pendingFill != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            commitFill()
        }
        .confirmationDialog(confirmationTitle(profile), isPresented: confirmationShown, presenting: confirmation) { kind in
            confirmationButtons(kind, profile: profile)
        } message: { kind in
            Text(verbatim: confirmationMessage(kind, profile: profile))
        }
        .alert(failure?.title ?? "", isPresented: failureShown, presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(verbatim: failure.message)
        }
    }

    // MARK: - Header

    @ViewBuilder private func headerSection(_ profile: Profile) -> some View {
        Section {
            if profile.isDefault {
                LabeledContent("Name", value: "Default")
                Text("Used whenever no Focus or desktop rule applies, and for anything another profile leaves empty. It can’t be renamed or deleted.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Name", text: $name, prompt: Text("Profile name"))
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            }
            LabeledContent("Showing now") {
                Text(showingNow(profile))
            }
            useNowRow(profile)
        }
    }

    @ViewBuilder private func useNowRow(_ profile: Profile) -> some View {
        // A Shortcuts choice is as sticky as a manual one, so it gets the same way out.
        let stickyNote = engine.focusProfileID == profile.id ? UIText.focusChoiceNote(engine.focusSource) : nil
        LabeledContent {
            if stickyNote != nil {
                Button("Stop Using") { engine.applyManually(profileID: nil) }
                    .help("Go back to what your Focus and desktop rules choose")
            } else {
                Button("Use Now") { engine.applyManually(profileID: profile.id) }
                    .help("Show this profile until the next Focus change (same as Apply Profile in the menu)")
            }
        } label: {
            Text(stickyNote ?? "Try it out without setting up a rule.")
                .foregroundStyle(.secondary)
        }
    }

    private func showingNow(_ profile: Profile) -> String {
        let dock = engine.resolution?.dock.profileID == profile.id
        let wallpaper = engine.resolution?.wallpaper.profileID == profile.id
        switch (dock, wallpaper) {
        case (true, true): return "Dock and wallpaper"
        case (true, false): return "Dock"
        case (false, true): return "Wallpaper"
        case (false, false): return "No"
        }
    }

    private func commitName() {
        guard let profile = store.profile(profileID), !profile.isDefault else { return }
        if name != profile.name { store.renameProfile(profileID, to: name) }
        name = store.profile(profileID)?.name ?? name   // Store trims / fills in "Untitled Profile"
    }

    private func commitFill() {
        guard let color = pendingFill else { return }
        pendingFill = nil
        guard var choice = store.profile(profileID)?.wallpaper else { return }
        choice.fillColor = ColorBridge.rgb(color)
        store.setWallpaper(choice, for: profileID)
    }

    // MARK: - Dock

    @ViewBuilder private func dockSection(_ profile: Profile) -> some View {
        Section {
            if let key = DockService.shared.managedKey() {
                Label(String("Your organization manages the Dock (\(key)), so DockShift can’t change it."),
                      systemImage: "lock.fill")
            }
            if profile.hasDock && store.isDockUnreadable(profile.id) {
                Label("The saved Dock can’t be read right now, so it isn’t applied. Capture the Dock again to replace it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } else if profile.hasDock {
                DockPreviewView(tiles: tiles)
                if let date = profile.dockCapturedAt {
                    LabeledContent("Captured", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                let missing = tiles.filter(\.isMissing).count
                if missing > 0 {
                    Label(missing == 1
                          ? "1 item isn’t on this Mac any more. It’s skipped when this Dock is applied."
                          : "\(missing) items aren’t on this Mac any more. They’re skipped when this Dock is applied.",
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            } else {
                Text(profile.isDefault
                     ? "No Dock saved. DockShift leaves your Dock as it is when no other rule sets one."
                     : "No Dock saved. While this profile is active, the Dock comes from the next rule that sets one, or from Default.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Capture Current Dock") {
                    if profile.hasDock { confirmation = .replaceDock } else { captureDock() }
                }
                .help("Save the apps, folders and spacers in your Dock right now into this profile")
                if profile.hasDock && !profile.isDefault {
                    Button("Clear") { confirmation = .clearDock }
                        .help("Remove this profile’s Dock so it inherits one")
                }
            }
        } header: {
            Label("Dock", systemImage: "dock.rectangle")
        } footer: {
            Text(dockFooter(profile)).foregroundStyle(.secondary)
        }
    }

    /// Edits to the live Dock belong to the profile that is showing it: arranging the Dock for
    /// another profile first needs that profile on screen, or a rule change in between saves the
    /// arrangement into the one showing.
    private func dockFooter(_ profile: Profile) -> String {
        let rt = store.runtime
        guard rt.appliedDockOK && rt.appliedDockProfileID == profile.id else {
            return "To set up this Dock, click Use Now, then arrange the Dock and click Capture Current Dock."
        }
        return store.settings.rememberDockEdits
            ? "This profile’s Dock is showing now. Changes you make to the Dock are saved into it before DockShift switches to another Dock; Capture Current Dock saves them right away."
            : "This profile’s Dock is showing now. Arrange it the way you want, then click Capture Current Dock."
    }

    private func captureDock() {
        do { try engine.captureCurrentDock(into: profileID) }
        catch { failure = Failure(title: "Couldn’t capture the Dock", message: error.localizedDescription) }
    }

    // MARK: - Wallpaper

    @ViewBuilder private func wallpaperSection(_ profile: Profile) -> some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                WallpaperThumbnail(url: profile.wallpaper.map { store.fileURL(for: $0) })
                    .frame(width: 200)
                VStack(alignment: .leading, spacing: 6) {
                    if let choice = profile.wallpaper {
                        Text(verbatim: choice.displayName).font(.headline).lineLimit(2)
                        if !store.wallpaperFileExists(choice) {
                            Label("The image file is missing. Choose it again.", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        } else if profile.isDefault {
                            Text("Shown on every desktop and display that no Focus or desktop rule gives a wallpaper.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("No wallpaper").font(.headline)
                        Text(profile.isDefault
                             ? "DockShift leaves your own wallpapers alone. When a Focus or desktop rule stops applying, the picture you had there is put back. Choose an image only if you want one wallpaper everywhere no rule sets one."
                             : "Uses the wallpaper of the next rule that sets one, or Default’s. If none does, each desktop keeps its own picture.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    HStack {
                        Button("Choose Image…") { chooseImage(for: profile) }
                        Button("Use Current Wallpaper") { captureWallpaper() }
                            .help("Use the wallpaper on your main display right now")
                    }
                    if profile.wallpaper != nil {
                        Button("Clear") { confirmation = .clearWallpaper }
                            .help("Remove this profile’s wallpaper so it inherits one")
                    }
                }
            }
            .padding(.vertical, 2)

            if let choice = profile.wallpaper {
                Picker("Placement", selection: placementBinding(choice)) {
                    ForEach(Placement.allCases) { Text($0.title).tag($0) }
                }
                if choice.placement == .fit || choice.placement == .center {
                    ColorPicker("Fill color", selection: fillBinding(choice), supportsOpacity: false)
                        .help("Shown around the image where it doesn’t cover the screen")
                }
            }
        } header: {
            Label("Wallpaper", systemImage: "photo")
        }
    }

    private func placementBinding(_ choice: WallpaperChoice) -> Binding<Placement> {
        Binding(
            get: { store.profile(profileID)?.wallpaper?.placement ?? choice.placement },
            set: { placement in
                guard var current = store.profile(profileID)?.wallpaper else { return }
                current.placement = placement
                store.setWallpaper(current, for: profileID)
            })
    }

    private func fillBinding(_ choice: WallpaperChoice) -> Binding<Color> {
        Binding(
            get: { pendingFill ?? ColorBridge.color(store.profile(profileID)?.wallpaper?.fillColor ?? choice.fillColor) },
            set: { pendingFill = $0 })
    }

    private func chooseImage(for profile: Profile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String("Choose a wallpaper for “\(profile.name)”. DockShift keeps its own copy of the image.")
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let choice = try store.ingestWallpaper(from: url,
                                                   placement: profile.wallpaper?.placement ?? .fill,
                                                   fillColor: profile.wallpaper?.fillColor ?? .black)
            store.setWallpaper(choice, for: profileID)
        } catch {
            failure = Failure(title: "Couldn’t use that image", message: error.localizedDescription)
        }
    }

    private func captureWallpaper() {
        do { try engine.captureCurrentWallpaper(into: profileID) }
        catch {
            failure = Failure(title: "Couldn’t use the current wallpaper",
                              message: error.localizedDescription + "\n\nApple’s Aerial and other live wallpapers can’t be captured. Use Choose Image… to pick an image file instead.")
        }
    }

    // MARK: - Used by

    @ViewBuilder private func usedBySection(_ profile: Profile) -> some View {
        Section("Used By") {
            if profile.isDefault {
                Label("Every desktop and Focus without its own rule", systemImage: "house")
            }

            let desktops = assignedDesktops(profile.id)
            LabeledContent {
                Button(desktops.isEmpty ? "Assign Desktops…" : "Change…") { navigate(.desktops) }
            } label: {
                Label {
                    Text(verbatim: desktops.isEmpty ? "No desktops" : desktops.joined(separator: ", "))
                } icon: {
                    Image(systemName: "rectangle.3.group")
                }
            }

            LabeledContent {
                Button("Open Focus Settings") { SystemLinks.openFocusSettings() }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus modes")
                        Text(verbatim: focusLine(profile))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "moon")
                }
            }
        }
    }

    private func focusLine(_ profile: Profile) -> String {
        var line = "Focus modes are linked in System Settings: add the DockShift filter to a Focus and choose “\(profile.name)”."
        if engine.focusProfileID == profile.id {
            line += " Active now (\(UIText.focusSource(engine.focusSource)))."
        }
        return line
    }

    /// Current Mission Control labels of the desktops assigned to this profile (labels shift when
    /// desktops are reordered, so prefer the live label over the stored one).
    private func assignedDesktops(_ id: ProfileID) -> [String] {
        let live = Dictionary(engine.desktops.map { ($0.ruleKey, $0) }, uniquingKeysWith: { first, _ in first })
        return store.config.spaceAssignments
            .filter { $0.value.profileID == id }
            .map { key, assignment in
                if let desktop = live[key] { return desktop.label }
                return "\(assignment.lastSeenLabel) (not present)"
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Confirmations

    private var confirmationShown: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private func confirmationTitle(_ profile: Profile) -> String {
        switch confirmation {
        case .replaceDock?: return "Replace the saved Dock of “\(profile.name)”?"
        case .clearDock?: return "Clear the Dock of “\(profile.name)”?"
        case .clearWallpaper?: return "Clear the wallpaper of “\(profile.name)”?"
        case .delete?: return "Delete “\(profile.name)”?"
        case nil: return ""
        }
    }

    private func confirmationMessage(_ kind: Confirmation, profile: Profile) -> String {
        switch kind {
        case .replaceDock:
            return "The Dock layout saved in this profile is replaced by the Dock you have right now."
        case .clearDock:
            return "This profile will no longer have its own Dock. It uses the Dock from the next rule that sets one, or from Default."
        case .clearWallpaper:
            return profile.isDefault
                ? "Wherever Default’s wallpaper is showing, DockShift puts back the picture that was there before. After that it leaves your wallpapers alone unless another rule sets one."
                : "This profile will no longer have its own wallpaper. It uses the wallpaper of the next rule that sets one, or Default’s."
        case .delete:
            let count = store.config.spaceAssignments.values.filter { $0.profileID == profile.id }.count
            var text = "Its Dock layout and wallpaper setting are removed."
            if count > 0 {
                text += count == 1 ? " The desktop that uses it goes back to no rule." : " The \(count) desktops that use it go back to no rule."
            }
            if engine.focusProfileID == profile.id, UIText.focusChoiceNote(engine.focusSource) != nil {
                text += " It’s the profile chosen for the Focus layer right now; that choice is cleared."
            }
            text += " Focus filters that pick it fall back to the desktop’s rule or Default. This can’t be undone."
            return text
        }
    }

    @ViewBuilder private func confirmationButtons(_ kind: Confirmation, profile: Profile) -> some View {
        switch kind {
        case .replaceDock:
            Button("Replace Dock") { captureDock() }
        case .clearDock:
            Button("Clear Dock", role: .destructive) { store.setDockSnapshot(nil, for: profile.id) }
        case .clearWallpaper:
            Button("Clear Wallpaper", role: .destructive) { store.setWallpaper(nil, for: profile.id) }
        case .delete:
            Button("Delete Profile", role: .destructive) {
                engine.deleteProfile(profile.id)   // also hands a manual/Shortcuts Focus choice of it back
                navigate(store.defaultProfile.map { .profile($0.id) } ?? .getStarted)
            }
        }
        Button("Cancel", role: .cancel) {}
    }
}
