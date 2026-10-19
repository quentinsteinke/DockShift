// GetStartedView.swift — DockShift
// First page of the window: the three things a new user has to do, each with a button that
// takes them there and a checkmark once it's done.
import SwiftUI
import AppKit

struct GetStartedView: View {
    var navigate: (SidebarItem) -> Void
    var newProfile: () -> Void

    private let store = Store.shared
    private let engine = Engine.shared
    private let focus = FocusRouter.shared

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to DockShift").font(.title2.weight(.semibold))
                        Text("Give every Focus mode and every desktop its own Dock and wallpaper.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let warning = store.configWarning {
                // Otherwise a recovered settings file would look like a clean first run.
                Section {
                    Label {
                        Text(verbatim: warning.text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                    HStack {
                        Spacer()
                        StoreWarningButtons(warning: warning)
                    }
                }
            }

            Section("Set Up in Three Steps") {
                StepRow(number: 1, title: "Save a profile",
                        detail: "A profile is a Dock layout plus a wallpaper. Arrange your Dock and wallpaper the way you want them, then save them as a profile.",
                        done: customProfileCount > 0) {
                    HStack {
                        Button("Create Profile from Current Setup…", action: newProfile)
                            .buttonStyle(.borderedProminent)
                        if customProfileCount > 0 {
                            Text(customProfileCount == 1 ? "1 profile so far" : "\(customProfileCount) profiles so far")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                StepRow(number: 2, title: "Link a Focus mode",
                        detail: "In System Settings, add DockShift’s Focus filter to a Focus (for example Work) and pick a profile. It switches when that Focus turns on and back when it turns off.",
                        done: focusLinked) {
                    HStack {
                        Button("Show Me How") { navigate(.focus) }
                        Button("Open Focus Settings") { SystemLinks.openFocusSettings() }
                    }
                }

                StepRow(number: 3, title: "Give desktops their own profile",
                        detail: "Pick a profile for any desktop in Mission Control. Switching to that desktop shows its Dock and wallpaper.",
                        done: assignedDesktopCount > 0) {
                    HStack {
                        Button("Assign Desktops") { navigate(.desktops) }
                        if assignedDesktopCount > 0 {
                            Text(assignedDesktopCount == 1 ? "1 desktop assigned" : "\(assignedDesktopCount) desktops assigned")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Good to Know") {
                if let defaultProfile = store.defaultProfile {
                    infoRow("house",
                            "“Default” holds the Dock you had when DockShift first opened. It’s used whenever no Focus or desktop rule applies.") {
                        Button("Open Default") { navigate(.profile(defaultProfile.id)) }
                    }
                }
                infoRow("arrow.uturn.backward.circle",
                        "An untouched copy of your original Dock is kept, and so is every wallpaper DockShift replaces. “Restore Original Dock & Wallpaper…” in the menu puts them back at any time.") {
                    EmptyView()
                }
                infoRow("square.3.layers.3d.down.right",
                        "When a Focus and a desktop both pick a profile, the Focus wins (change this in Settings). Anything a profile leaves empty comes from the other rule, then from Default.") {
                    EmptyView()
                }
                infoRow("photo.on.rectangle",
                        "DockShift leaves your own wallpapers alone until a profile sets one. When that rule stops applying, the picture you had there is put back. macOS switches off “Show on all Spaces” once DockShift sets a desktop’s wallpaper.") {
                    EmptyView()
                }
                infoRow("power",
                        "DockShift only reacts while it’s running. Turn on “Open at login” so it’s always there.") {
                    Button("Settings") { navigate(.settings) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var customProfileCount: Int { store.profiles.filter { !$0.isDefault }.count }
    private var assignedDesktopCount: Int { store.config.spaceAssignments.count }

    /// No API says whether a Focus has the filter; a delivered filter event or a Focus-driven
    /// profile is proof enough.
    private var focusLinked: Bool {
        focus.lastFilterEvent != nil || focus.source == .filter || focus.source == .shortcuts
    }

    private func infoRow<B: View>(_ symbol: String, _ text: String, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            button()
        }
    }
}
