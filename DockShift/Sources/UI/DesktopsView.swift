// DesktopsView.swift — DockShift
// Per-desktop (Space) rules: one profile picker per Mission Control desktop, grouped by display,
// plus the switching options. Rules are keyed by the Space's persistent uuid (ruleKey), so they
// follow a desktop when it's reordered; labels like "Desktop 2" are only for display.
import SwiftUI
import AppKit

struct DesktopsView: View {
    private let store = Store.shared
    private let engine = Engine.shared

    @State private var dwell: Double = Store.shared.settings.desktopDockDwell
    @State private var showOnAllSpaces: Bool?

    var body: some View {
        Form {
            if engine.spacesAvailable {
                Section {
                    Text("Choose a profile for a desktop and DockShift shows its Dock and wallpaper whenever you switch to it. Desktops without a rule show your Focus profile or Default; if neither sets a wallpaper, the desktop keeps its own picture.")
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Need another desktop?") {
                        Button("Open Mission Control") { SystemLinks.openApp(bundleIdentifier: "com.apple.exposelauncher") }
                            .help("Click + at the top of Mission Control to add a desktop")
                    }
                }
                desktopSections
                orphanSection
            } else {
                Section {
                    Label("DockShift can’t tell desktops apart on this version of macOS.",
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text("Desktop rules rely on a part of macOS that isn’t available right now. Focus modes and the Default profile still work.")
                        .foregroundStyle(.secondary)
                }
            }
            optionsSection
        }
        .formStyle(.grouped)
        .task { showOnAllSpaces = WallpaperService.shared.showOnAllSpaces() }
        .task(id: dwell) {
            // The slider reports every step; save once it settles.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commitDwell()
        }
        .onDisappear(perform: commitDwell)   // the debounce above is cancelled with the view
    }

    private func commitDwell() {
        guard store.settings.desktopDockDwell != dwell else { return }
        store.updateSettings { $0.desktopDockDwell = dwell }
    }

    // MARK: - Desktops

    private struct DisplayGroup: Identifiable {
        let id: String              // display identifier ("Main" or a display UUID)
        let title: String
        let desktops: [SpaceDescriptor]
    }

    /// Engine.desktops is in Mission Control order; keep displays in first-seen order too.
    private var groups: [DisplayGroup] {
        var order: [String] = []
        var byDisplay: [String: [SpaceDescriptor]] = [:]
        for desktop in engine.desktops {
            if byDisplay[desktop.displayIdentifier] == nil { order.append(desktop.displayIdentifier) }
            byDisplay[desktop.displayIdentifier, default: []].append(desktop)
        }
        return order.enumerated().map { index, id in
            var title = "Desktops"
            if engine.displayCount > 1 {
                title = "Display \(index + 1)"
                if let name = WallpaperService.shared.screens(forDisplayIdentifier: id).first?.localizedName {
                    title += " — \(name)"
                }
            }
            return DisplayGroup(id: id, title: title, desktops: byDisplay[id] ?? [])
        }
    }

    @ViewBuilder private var desktopSections: some View {
        let groups = groups
        if groups.isEmpty {
            Section("Desktops") {
                Text("Looking for desktops…").foregroundStyle(.secondary)
            }
        } else {
            let current = currentSpaceIDs
            ForEach(groups) { group in
                Section {
                    ForEach(group.desktops, id: \.managedID) { desktop in
                        desktopRow(desktop, isCurrent: current.contains(desktop.managedID))
                    }
                } header: {
                    Text(verbatim: group.title)
                } footer: {
                    if group.id == groups.last?.id {
                        Text("Full-screen apps aren’t desktops: while one is showing, DockShift keeps the last desktop’s Dock.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func desktopRow(_ desktop: SpaceDescriptor, isCurrent: Bool) -> some View {
        Picker(selection: assignmentBinding(desktop)) {
            Text("No rule").tag(ProfileID?.none)
            Divider()
            ForEach(store.profiles) { profile in
                Text(verbatim: profile.name).tag(ProfileID?.some(profile.id))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "menubar.rectangle").foregroundStyle(.secondary)
                Text(verbatim: desktop.label)
                if isCurrent { TagText("Current") }
            }
        }
    }

    /// Current Space of every display (the Engine only tracks the menu-bar display's).
    private var currentSpaceIDs: Set<UInt64> {
        var ids = Set(SpaceReader.snapshot()?.currentByDisplay.values.map { $0 } ?? [])
        if let current = engine.currentDesktop { ids.insert(current.managedID) }
        return ids
    }

    private func assignmentBinding(_ desktop: SpaceDescriptor) -> Binding<ProfileID?> {
        Binding(
            get: {
                guard let id = store.assignment(forSpaceKey: desktop.ruleKey)?.profileID,
                      store.profile(id) != nil else { return nil }
                return id
            },
            set: { id in
                store.setAssignment(profileID: id, spaceKey: desktop.ruleKey,
                                    displayIdentifier: desktop.displayIdentifier, label: desktop.label)
            })
    }

    // MARK: - Orphans

    @ViewBuilder private var orphanSection: some View {
        // Before the Engine has listed desktops every rule would look orphaned.
        if !engine.desktops.isEmpty {
            let live = Set(engine.desktops.map(\.ruleKey))
            let orphans = store.config.spaceAssignments
                .filter { !live.contains($0.key) }
                .sorted { $0.value.lastSeenLabel.localizedStandardCompare($1.value.lastSeenLabel) == .orderedAscending }
            if !orphans.isEmpty {
                Section {
                    ForEach(orphans, id: \.key) { key, assignment in
                        LabeledContent {
                            Button("Remove") {
                                store.setAssignment(profileID: nil, spaceKey: key,
                                                    displayIdentifier: assignment.displayIdentifier,
                                                    label: assignment.lastSeenLabel)
                            }
                        } label: {
                            Text(verbatim: assignment.lastSeenLabel)
                            Text(verbatim: "Profile: \(engine.profileName(assignment.profileID))")
                        }
                    }
                } header: {
                    Text("Rules for Desktops That Aren’t There")
                } footer: {
                    Text("These desktops were closed in Mission Control or are on a display that isn’t connected. A rule comes back into use if its desktop returns.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        Section {
            Toggle(isOn: settingBinding(\.switchDockPerDesktop)) {
                Text("Change Dock when switching desktops")
                Text("Switching layouts restarts the Dock (a brief flicker). It only happens when the new desktop’s Dock is different.")
            }

            LabeledContent {
                HStack {
                    Slider(value: $dwell, in: 0.5...3, step: 0.1)
                        .frame(maxWidth: 220)
                        .accessibilityValue(Text(verbatim: dwellText))
                    Text(verbatim: dwellText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            } label: {
                Text("Wait before changing the Dock")
                Text("So swiping past a desktop doesn’t restart the Dock for it.")
            }
            .disabled(!store.settings.switchDockPerDesktop)
        } header: {
            Text("When Switching Desktops")
        } footer: {
            Text(showOnAllSpaces == true
                 ? "“Show on all Spaces” is on in System Settings › Wallpaper. macOS switches it off once DockShift sets a desktop’s wallpaper."
                 : "macOS switches off “Show on all Spaces” once DockShift sets a desktop’s wallpaper.")
                .foregroundStyle(.secondary)
        }
    }

    private var dwellText: String { String(format: "%.1f s", dwell) }

    private func settingBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
    }
}
