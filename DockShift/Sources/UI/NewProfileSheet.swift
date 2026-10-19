// NewProfileSheet.swift — DockShift
// Creating a profile. The main path is "save what I have right now": arrange the Dock and
// wallpaper first, then name it. An empty profile is offered for people who only want to change
// one half (e.g. just a wallpaper for a desktop). When the current setup can't give the profile a
// wallpaper (desktops showing different ones, a live wallpaper), the sheet stays open to say so.
import SwiftUI

struct NewProfileSheet: View {
    var onCreated: (ProfileID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start: StartPoint = .current
    @State private var errorText: String?
    /// Set after a creation that left something out: the sheet shows `note` until Done.
    @State private var created: CreatedProfile?
    private let engine = Engine.shared
    private let store = Store.shared

    private enum StartPoint: Hashable { case current, empty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let created, let note = created.note {
                    Section {
                        Label(note, systemImage: "info.circle")
                    } header: {
                        Text("Created “\(created.profile.name)”").font(.title3.weight(.semibold))
                    }
                } else {
                    setupSections
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                if created != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create Profile") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var setupSections: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("Work, Personal, Gaming…"))
        } header: {
            Text("New Profile").font(.title3.weight(.semibold))
        } footer: {
            Text("A profile is a Dock layout plus a wallpaper. Link it to a Focus mode or a desktop afterwards.")
                .foregroundStyle(.secondary)
        }

        Section {
            Picker("Start with", selection: $start) {
                Text("My current Dock and wallpaper").tag(StartPoint.current)
                Text("Nothing yet (inherit the Dock and wallpaper)").tag(StartPoint.empty)
            }
            .pickerStyle(.radioGroup)
        } footer: {
            Text(start == .current
                 ? "The new profile stays in use until your next Focus change (or choose Stop Using). Dock edits you make meanwhile are saved into it. The wallpaper is included when all your desktops show the same one."
                 : "You can capture a Dock or choose a wallpaper for it afterwards. Anything left empty comes from the next rule that sets it, or from Default.")
                .foregroundStyle(.secondary)
        }

        if let errorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        do {
            if start == .current {
                let result = try engine.createProfileFromCurrentSetup(name: trimmedName)
                onCreated(result.profile.id)
                // Stay open so what was left out is seen; the profile page is already behind the sheet.
                if result.note != nil {
                    created = result
                    return
                }
            } else {
                onCreated(store.createProfile(name: trimmedName, isDefault: false).id)
            }
            dismiss()
        } catch {
            errorText = "Couldn’t capture your current setup: \(error.localizedDescription)"
        }
    }
}
