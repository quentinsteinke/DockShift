// Models.swift — DockShift
// Shared value types. Everything here is a plain Sendable value; persistence lives in Store,
// side effects live in the services and the Engine.
import Foundation

typealias ProfileID = UUID

// MARK: - Wallpaper

/// How a wallpaper image is fitted to the screen. Raw values match the placement ids used by
/// the macOS wallpaper store and by the private per-Space setter (`DesktopPictureSetDisplayForSpace`).
enum Placement: String, Codable, CaseIterable, Identifiable, Sendable {
    case fill = "Crop"          // Fill Screen (scale proportionally, clip)
    case fit = "SizeToFit"      // Fit to Screen (scale proportionally, no clipping)
    case stretch = "FillScreen" // Stretch to Fill Screen
    case center = "Centered"    // Center, no scaling

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: return "Fill Screen"
        case .fit: return "Fit to Screen"
        case .stretch: return "Stretch to Fill Screen"
        case .center: return "Center"
        }
    }
}

struct RGBColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0, green: 0, blue: 0)
}

/// A wallpaper owned by DockShift. The image is a content-addressed copy inside
/// `Store.wallpapersDirectory`, so later edits/moves of the user's original file don't matter.
struct WallpaperChoice: Codable, Hashable, Sendable {
    /// File name inside `Store.wallpapersDirectory`, e.g. "3f2a…e9.jpg" (sha256 of the bytes + extension).
    var fileName: String
    /// Name of the file the user picked, for display only.
    var displayName: String
    var placement: Placement = .fill
    var fillColor: RGBColor = .black
}

/// A picture as one wallpaper slot (display × desktop) shows it. Unlike `WallpaperChoice` the file
/// can live anywhere (e.g. the user's own wallpaper), so it is stored as an absolute path.
struct SlotPicture: Codable, Hashable, Sendable {
    var path: String
    var placement: Placement
    var fillColor: RGBColor
    /// For a baseline: the user's own file that `path` (DockShift's copy) was made from. Put back in
    /// preference to the copy while it is still the same picture, so System Settings shows their
    /// file. nil = `path` is the file itself. Optional: records of older builds lack it.
    var sourcePath: String? = nil
}

/// DockShift's record of one wallpaper slot it changed. Persisted (wallpaper-slots.json) so that
/// after a relaunch DockShift still knows what it wrote and what to put back.
struct WallpaperSlot: Codable, Hashable, Sendable {
    /// What DockShift last put on this slot. While the desired choice still equals this, the slot is
    /// left alone — so a picture the user sets in System Settings afterwards sticks.
    var applied: WallpaperChoice
    /// What the slot showed before DockShift first changed it; written back when no rule wants the
    /// slot any more. nil = DockShift couldn't tell (`note` says why); put-back then reports the slot.
    var baseline: SlotPicture?
    /// Human-readable name for logs and UI, e.g. "Desktop 2 · Built-in Retina Display".
    var label: String
    /// Why the baseline isn't exactly what the slot showed, e.g. a live wallpaper that comes back
    /// as a still image, or why there is none.
    var note: String? = nil
    /// false while DockShift's last write here (of `applied`, or of the baseline being put back)
    /// isn't confirmed: it may still land, so the slot may show either picture.
    var confirmed: Bool = true
}

extension WallpaperSlot {
    // In an extension so the memberwise initializer stays. Records of older builds lack the
    // newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applied = try c.decode(WallpaperChoice.self, forKey: .applied)
        baseline = try c.decodeIfPresent(SlotPicture.self, forKey: .baseline)
        label = try c.decode(String.self, forKey: .label)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? true
    }
}

// MARK: - Dock

/// A captured Dock layout: `persistent-apps` and `persistent-others` exactly as the Dock wrote
/// them, each stored as an opaque binary-plist blob (avoids NSNumber Bool/Int drift and Int64
/// truncation that a JSON round-trip would cause).
struct DockSnapshot: Codable, Hashable, Sendable {
    var persistentApps: Data      // binary plist of [[String: Any]]
    var persistentOthers: Data    // binary plist of [[String: Any]]
    var capturedAt: Date
    var osVersion: String
}

/// UI/preview description of one Dock tile.
struct DockTileInfo: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case app, file, folder, url, spacer, smallSpacer, flexSpacer, other }
    enum Section: String, Sendable { case apps, others }

    let id: String                // "\(section)-\(index)"
    let section: Section
    let kind: Kind
    let label: String
    let path: String?             // resolved file-system path (apps/files/folders)
    let bundleIdentifier: String?
    let urlString: String?        // url-tile target
    let isMissing: Bool           // target can't be found on disk any more
}

// MARK: - Profiles & rules

/// A named Dock + wallpaper combination. Either half may be absent, meaning "inherit"
/// (fall through to the next rule layer, ending at the Default profile).
struct Profile: Codable, Identifiable, Hashable, Sendable {
    var id: ProfileID
    var name: String
    /// The Default profile is used when no Focus/desktop rule supplies a value. Exactly one exists.
    var isDefault: Bool
    /// True when `Store` holds a DockSnapshot for this profile (Docks/<id>.plist).
    var hasDock: Bool
    /// Bumped every time the profile's DockSnapshot is replaced.
    var dockRevision: Int
    var dockCapturedAt: Date?
    /// nil = inherit.
    var wallpaper: WallpaperChoice?
    var createdAt: Date
}

/// A per-desktop (Space) rule. Keyed in `DockShiftConfig.spaceAssignments` by
/// `SpaceDescriptor.ruleKey` (the Space's persistent uuid, or "main-desktop" for the original
/// desktop whose uuid is "").
struct SpaceAssignment: Codable, Hashable, Sendable {
    var profileID: ProfileID
    /// Display the Space was last seen on ("Main" or a display UUID). Informational.
    var displayIdentifier: String
    /// Label last shown for it, e.g. "Desktop 2". Informational (labels shift when Spaces reorder).
    var lastSeenLabel: String
}

enum Precedence: String, Codable, CaseIterable, Identifiable, Sendable {
    case focusWins
    case desktopWins

    var id: String { rawValue }
    var title: String { self == .focusWins ? "Focus wins" : "Desktop wins" }
}

struct AppSettings: Codable, Hashable, Sendable {
    /// When paused nothing is applied automatically.
    var paused = false
    /// Which rule layer wins when both a Focus and a desktop rule set the Dock.
    var dockPrecedence: Precedence = .focusWins
    /// Which rule layer wins when both a Focus and a desktop rule set the wallpaper.
    var wallpaperPrecedence: Precedence = .focusWins
    /// Apply per-desktop Dock rules when switching desktops (each switch restarts the Dock).
    var switchDockPerDesktop = true
    /// How long to stay on a desktop before its Dock is applied (seconds).
    var desktopDockDwell: Double = 1.2
    /// Before switching away from a profile's Dock, save manual Dock edits back into it.
    var rememberDockEdits = true
    /// Unused since wallpaper design v2 (every desktop is written whenever macOS allows it); kept
    /// so configs round-trip across builds.
    var preloadDesktopWallpapers = true

    init() {}

    // Tolerate configs written by older builds that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        dockPrecedence = try c.decodeIfPresent(Precedence.self, forKey: .dockPrecedence) ?? d.dockPrecedence
        wallpaperPrecedence = try c.decodeIfPresent(Precedence.self, forKey: .wallpaperPrecedence) ?? d.wallpaperPrecedence
        switchDockPerDesktop = try c.decodeIfPresent(Bool.self, forKey: .switchDockPerDesktop) ?? d.switchDockPerDesktop
        desktopDockDwell = try c.decodeIfPresent(Double.self, forKey: .desktopDockDwell) ?? d.desktopDockDwell
        rememberDockEdits = try c.decodeIfPresent(Bool.self, forKey: .rememberDockEdits) ?? d.rememberDockEdits
        preloadDesktopWallpapers = try c.decodeIfPresent(Bool.self, forKey: .preloadDesktopWallpapers) ?? d.preloadDesktopWallpapers
    }
}

/// Everything persisted in config.json.
struct DockShiftConfig: Codable, Sendable {
    var version = 1
    var profiles: [Profile] = []
    /// Key: `SpaceDescriptor.ruleKey`.
    var spaceAssignments: [String: SpaceAssignment] = [:]
    var settings = AppSettings()
}

/// Lightweight profile listing used by App Intents (read straight from config.json on disk).
struct ProfileSummary: Hashable, Sendable {
    let id: ProfileID
    let name: String
    let isDefault: Bool
}

/// What DockShift last did to the Dock. Persisted in state.json so a relaunch can tell a user's
/// manual Dock edit apart from a layout DockShift applied itself.
struct RuntimeState: Codable, Sendable {
    var appliedDockProfileID: ProfileID?
    var appliedDockRevision: Int?
    /// `DockService.identity(...)` of the live Dock right after the last successful apply/verify.
    var appliedDockIdentity: [String]?
    var appliedDockOK = false
    var appliedAt: Date?
}

// MARK: - Focus

/// Where the current Focus-layer profile came from.
enum FocusSource: String, Codable, Sendable {
    case none        // no Focus profile active
    case filter      // DockShift's Focus filter (System Settings › Focus › … › Focus Filters)
    case shortcuts   // "Set DockShift Focus Profile" App Intent, e.g. from a Shortcuts Focus automation
    case manual      // chosen from DockShift's menu ("Apply Profile")
}

// MARK: - Resolution

/// Which rule layer produced a channel's value.
enum RuleSource: Hashable, Sendable {
    case focus
    case desktop(String)    // SpaceDescriptor.ruleKey
    case defaultProfile
    case none               // nothing configured: leave the system as it is
}

struct ChannelResolution: Hashable, Sendable {
    /// Profile whose Dock / wallpaper should be shown. nil = don't touch.
    var profileID: ProfileID?
    var source: RuleSource
}

struct Resolution: Hashable, Sendable {
    var dock: ChannelResolution
    var wallpaper: ChannelResolution
}
