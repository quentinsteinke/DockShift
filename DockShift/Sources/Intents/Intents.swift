// Intents.swift — DockShift
// App Intents surface: the Focus filter (primary Focus → profile mapping, configured in
// System Settings › Focus) and a plain intent for Shortcuts Focus automations (fallback).
// Everything here only hands values to FocusRouter; applying a profile can take seconds
// (Dock restart + verify), and perform() must return promptly.
import AppIntents
import Foundation

struct ProfileEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "DockShift Profile"
    static let defaultQuery = ProfileEntityQuery()

    /// The profile's UUID: stable across renames, so a Focus keeps its profile when it's renamed.
    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// System Settings and Shortcuts evaluate this outside DockShift's UI state, possibly before the
/// app has finished launching, so it reads config.json from disk instead of the main-actor Store.
struct ProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [ProfileEntity.ID]) async throws -> [ProfileEntity] {
        let byID = Dictionary(Self.load().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A deleted profile simply resolves to nothing; the Resolver then falls through to Default.
        return identifiers.compactMap { byID[$0] }
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        Self.load()
    }

    private static func load() -> [ProfileEntity] {
        Store.profileSummariesFromDisk().map { ProfileEntity(id: $0.id, name: $0.name) }
    }
}

/// Appears under System Settings › Focus › <Focus> › Focus Filters › Add Filter › DockShift.
struct DockShiftFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Dock & Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Use a DockShift profile's Dock and wallpaper while this Focus is on.")

    /// MUST stay optional with no default: turning the Focus off delivers default values, so
    /// nil is the only "Focus ended" signal (a default would make off look like on).
    @Parameter(title: "Profile")
    var profile: ProfileEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "DockShift", subtitle: "\(profile?.name ?? "No profile")")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusRouter.shared.filterDelivered(profileID: profile?.id)
        return .result()
    }
}

/// For "When <Focus> Is Turned On/Off" Shortcuts automations (macOS 26+), in case Focus-filter
/// delivery is broken on this macOS release. Independent of the filter's delivery path.
struct SetFocusProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Set DockShift Focus Profile"
    static let description: IntentDescription? = IntentDescription(
        "Choose the DockShift profile for the Focus layer, e.g. from a Focus automation. Leave Profile empty when the Focus turns off.")

    /// nil = clear the Focus layer.
    @Parameter(title: "Profile")
    var profile: ProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Use \(\.$profile) for the Focus layer")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusRouter.shared.explicitRequest(profileID: profile?.id, source: .shortcuts)
        return .result()
    }
}
