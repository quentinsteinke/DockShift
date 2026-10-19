// FocusSetupView.swift — DockShift
// Focus → profile mapping lives in System Settings (DockShift's Focus filter), not in DockShift,
// because apps can't list Focus modes. This page walks the user there and shows live status.
import SwiftUI
import AppKit

struct FocusSetupView: View {
    var newProfile: () -> Void

    private let store = Store.shared
    private let engine = Engine.shared
    private let focus = FocusRouter.shared
    @State private var showShortcutsFallback = false

    var body: some View {
        Form {
            Section {
                Text("Each Focus mode can switch to one of your profiles. You link them in System Settings by adding DockShift’s Focus filter to a Focus. When the Focus turns on, DockShift shows that profile; when it turns off, DockShift goes back.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Set Up") {
                StepRow(number: 1, title: "Create a profile for the Focus",
                        detail: profileStepDetail,
                        done: customProfileCount > 0) {
                    Button("New Profile…", action: newProfile)
                }
                StepRow(number: 2, title: "Open Focus settings",
                        detail: "System Settings opens on Focus.") {
                    Button("Open Focus Settings") { SystemLinks.openFocusSettings() }
                        .buttonStyle(.borderedProminent)
                }
                StepRow(number: 3, title: "Add the DockShift filter",
                        detail: "Click a Focus (for example Work), scroll down to Focus Filters, click Add Filter, choose DockShift, then pick a profile and click Add.")
                StepRow(number: 4, title: "Repeat for other Focus modes",
                        detail: "Each Focus can use a different profile. A Focus without the DockShift filter doesn’t change anything: you’ll see your desktop’s profile or Default.")
            }

            statusSection

            Section {
                Label("Focus changes only reach DockShift while it’s running.", systemImage: "power")
                LaunchAtLoginControl()
            } header: {
                Text("Keep DockShift Running")
            }

            Section {
                DisclosureGroup("Fallback: Shortcuts automation", isExpanded: $showShortcutsFallback) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("If switching a Focus doesn’t change your profile, a Shortcuts automation can do it instead (macOS 26 or later).")
                            .fixedSize(horizontal: false, vertical: true)
                        StepRow(number: 1, title: "Turn-on automation",
                                detail: "In Shortcuts, choose Automation › New Automation › Focus. Pick the Focus, choose “Is Turned On” and “Run Immediately”.")
                        StepRow(number: 2, title: "Add DockShift’s action",
                                detail: "Add the action “Set DockShift Focus Profile” and choose the profile.")
                        StepRow(number: 3, title: "Turn-off automation",
                                detail: "Make a second automation for the same Focus with “Is Turned Off”, using the same action with no profile.")
                        Button("Open Shortcuts") { SystemLinks.openApp(bundleIdentifier: "com.apple.shortcuts") }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var customProfileCount: Int { store.profiles.filter { !$0.isDefault }.count }

    private var profileStepDetail: String {
        switch customProfileCount {
        case 0: return "Set up your Dock and wallpaper for the Focus, then save them as a profile."
        case 1: return "You have 1 profile besides Default. Make more for other Focus modes."
        default: return "You have \(customProfileCount) profiles besides Default."
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("Focus filter") {
                Text(verbatim: focus.filterStatus.isEmpty ? "Not checked yet" : focus.filterStatus)
            }
            LabeledContent("Last change from a Focus") {
                if let date = focus.lastFilterEvent {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("None yet")
                }
            }
            LabeledContent("Focus profile now") {
                Text(verbatim: UIText.focusSummary(engine: engine) ?? "None")
            }
            if engine.focusSource == .filter, let id = engine.focusProfileID, store.profile(id) == nil {
                Label("The DockShift filter of the Focus that’s on picks a profile that was deleted. Choose another profile for it in System Settings › Focus.",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            HStack {
                if let note = UIText.focusChoiceNote(engine.focusSource),
                   let clear = UIText.clearFocusTitle(engine.focusSource) {
                    Text(note).foregroundStyle(.secondary)
                    Spacer()
                    Button(clear) { engine.applyManually(profileID: nil) }
                } else {
                    Spacer()
                }
                Button("Check Now") { focus.reconcile(reason: "manual") }
                    .help("Ask macOS which Focus filter is active right now")
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Focus filters also work when a Focus turns on by schedule or from your iPhone.")
                .foregroundStyle(.secondary)
        }
    }
}
