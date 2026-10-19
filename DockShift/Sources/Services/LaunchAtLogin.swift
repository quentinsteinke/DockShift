// LaunchAtLogin.swift — DockShift
// Login item via SMAppService.mainApp. Focus-filter pushes only reach a running DockShift and
// are never replayed, so staying alive across logins is what keeps the Focus layer reliable.
import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// Registered, but switched off by the user in System Settings › General › Login Items.
    /// The user asked for it, so a toggle should show on (with a way to approve).
    static var needsApproval: Bool { status == .requiresApproval }

    /// The login item records the bundle that registered it, so only the /Applications copy may
    /// register; a DerivedData/build copy would be what launches at the next login.
    static var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    enum Failure: LocalizedError {
        case needsApproval
        var errorDescription: String? {
            "Allow DockShift in System Settings › General › Login Items."
        }
    }

    /// Turning it on while approval is pending opens Login Items instead: only the user can
    /// switch it back on there, and register() would just fail.
    static func set(_ on: Bool) throws {
        if on {
            switch status {
            case .enabled:
                return      // register() again fails with kSMErrorAlreadyRegistered
            case .requiresApproval:
                openSystemSettings()
                return
            default:
                break
            }
            do {
                try SMAppService.mainApp.register()
            } catch let error as NSError where isApprovalError(error) || status == .requiresApproval {
                Log.engine.notice("Launch at login needs approval (\(error.domain, privacy: .public) \(error.code, privacy: .public))")
                openSystemSettings()
                if status == .requiresApproval { return }     // the approval row explains it
                throw Failure.needsApproval
            }
        } else {
            guard status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
        Log.engine.notice("Launch at login \(on ? "enabled" : "disabled", privacy: .public) (status \(status.rawValue, privacy: .public))")
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func isApprovalError(_ error: NSError) -> Bool {
        error.domain == SMAppServiceErrorDomain
            && (error.code == kSMErrorLaunchDeniedByUser || error.code == kSMErrorAlreadyRegistered)
    }
}
