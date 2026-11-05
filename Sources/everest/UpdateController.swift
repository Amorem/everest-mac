import AppKit
import Combine
import Sparkle

/// App updates with Sparkle 2 (the keyboard's firmware is never touched).
/// Checks once a day; a new version downloads in the background and installs
/// on quit, or now with "Restart to Update". A scheduled check never opens a
/// window: a dot on the menu-bar icon and a menu item stand in for it.
///
/// Only release builds carry a feed (make-app.sh --release): a build from
/// source has no updater and shows nothing.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case available(String)
        case ready(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = true
    @Published private(set) var automaticInstall = true
    @Published private(set) var lastCheck: Date?

    /// False for a build from source.
    let isEnabled: Bool

    /// scripts/update-test.sh: no daemon, and it restarts by itself once the
    /// update is downloaded.
    nonisolated static let testMode = ProcessInfo.processInfo.environment["EVEREST_UPDATE_TEST"] != nil

    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var canCheckObservation: NSKeyValueObservation?
    private var started = false

    override init() {
        let info = Bundle.main.infoDictionary
        isEnabled = info?["SUFeedURL"] != nil && info?["SUPublicEDKey"] != nil
        super.init()
    }

    /// Starts Sparkle and checks once now (then every day).
    func start() {
        guard isEnabled, !started else { return }
        started = true
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
        do {
            try controller.updater.start()
        } catch {
            stderr("updates: Sparkle did not start: \(error.localizedDescription)")
            return
        }
        syncSettings()
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// "Check for Updates…": Sparkle's own window, in front.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// The menu item of a waiting update: restart into it, or show it.
    func performPrimaryAction() {
        if case .ready = phase, let installNow {
            installNow()
        } else {
            checkForUpdates()
        }
    }

    func setAutomaticChecks(_ value: Bool) {
        controller?.updater.automaticallyChecksForUpdates = value
        syncSettings()
    }

    func setAutomaticInstall(_ value: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = value
        syncSettings()
    }

    private func syncSettings() {
        guard let updater = controller?.updater else { return }
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticInstall = updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    /// Sparkle calls its delegates on the main thread; never trap if not.
    nonisolated private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        onMain {
            self.installNow = immediateInstallHandler
            self.phase = .ready(version)
            if Self.testMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.performPrimaryAction() }
            }
        }
        return true
    }

    /// Picture transfers use the keyboard's firmware-update mechanism: never
    /// restart in the middle of one, whichever process runs it.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard FlashBusy.active else { return false }
        func waitForTransfer() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if FlashBusy.active { waitForTransfer() } else { installHandler() }
            }
        }
        waitForTransfer()
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        onMain { self.lastCheck = updater.lastUpdateCheckDate }
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A menu-bar app never pops a window from a scheduled check.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let version = update.displayVersionString
        onMain {
            if case .ready = self.phase { return }
            self.phase = .available(version)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        onMain {
            if case .available = self.phase { self.phase = .idle }
        }
    }
}
