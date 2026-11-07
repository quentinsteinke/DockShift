import AppKit
import Combine
import Sparkle

/// Sparkle owns scheduling, signature verification, installation and relaunch. Profile data
/// stays in Application Support; the updater only replaces the application bundle.
@MainActor
final class UpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateService()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var configurationProblem: String?
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        configurationProblem = UpdateConfiguration.problem(in: Bundle.main.infoDictionary ?? [:])
        guard configurationProblem == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                     updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        do {
            try controller.updater.start()
        } catch {
            configurationProblem = "Updates couldn’t start: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        AppActivation.prepareToShowWindow()
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Finish an in-flight Dock/wallpaper operation and save manual edits before Sparkle
        // terminates this process. Do not persist a paused setting merely to install an update.
        Task {
            await Engine.shared.prepareForUpdate()
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        Engine.shared.resumeAfterUpdateCycle()
    }
}
