// Resolver.swift — DockShift
// Decides which profile supplies the Dock and which supplies the wallpaper. Pure: no I/O, no
// globals, so every decision the Engine makes can be reproduced from (config, focus, desktop).
import Foundation

enum Resolver {
    /// Pure. `desktopKey` = ruleKey of the desktop being resolved (nil = no desktop layer).
    static func resolve(config: DockShiftConfig, focusProfileID: ProfileID?, desktopKey: String?) -> Resolution {
        Resolution(dock: resolveDock(config: config, focusProfileID: focusProfileID, desktopKey: desktopKey),
                   wallpaper: resolveWallpaper(config: config, focusProfileID: focusProfileID, desktopKey: desktopKey))
    }

    static func resolveDock(config: DockShiftConfig, focusProfileID: ProfileID?, desktopKey: String?) -> ChannelResolution {
        // With per-desktop Docks off, desktop rules still drive the wallpaper but never the Dock,
        // so switching desktops can't restart the Dock.
        let key = config.settings.switchDockPerDesktop ? desktopKey : nil
        return resolveChannel(config: config, precedence: config.settings.dockPrecedence,
                              focusProfileID: focusProfileID, desktopKey: key) { $0.hasDock }
    }

    static func resolveWallpaper(config: DockShiftConfig, focusProfileID: ProfileID?, desktopKey: String?) -> ChannelResolution {
        resolveChannel(config: config, precedence: config.settings.wallpaperPrecedence,
                       focusProfileID: focusProfileID, desktopKey: desktopKey) { $0.wallpaper != nil }
    }

    /// Walks the layers in precedence order, then Default. A layer only wins when its profile
    /// still exists AND supplies this channel; otherwise it inherits from the next layer. A
    /// rule pointing at a deleted profile is therefore harmless rather than "blank the Dock".
    private static func resolveChannel(config: DockShiftConfig, precedence: Precedence,
                                       focusProfileID: ProfileID?, desktopKey: String?,
                                       supplies: (Profile) -> Bool) -> ChannelResolution {
        let focus: (RuleSource, ProfileID?) = (.focus, focusProfileID)
        let desktop: (RuleSource, ProfileID?) = desktopKey.map { (.desktop($0), config.spaceAssignments[$0]?.profileID) }
            ?? (.none, nil)
        let ordered = precedence == .focusWins ? [focus, desktop] : [desktop, focus]
        let layers = ordered + [(.defaultProfile, config.profiles.first { $0.isDefault }?.id)]

        for (source, id) in layers {
            guard let id, let profile = config.profiles.first(where: { $0.id == id }), supplies(profile) else { continue }
            return ChannelResolution(profileID: id, source: source)
        }
        // Even Default lacks this channel (e.g. its wallpaper was an Aerial): leave the system alone.
        return ChannelResolution(profileID: nil, source: .none)
    }
}
