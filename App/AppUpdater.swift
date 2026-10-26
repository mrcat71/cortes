import AppKit
import CortesKit
import Observation
import os
@preconcurrency import Sparkle

@MainActor @Observable
final class AppUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private(set) var problem: String?
    private(set) var canCheckForUpdates = false
    var automaticallyChecksForUpdates = false {
        didSet {
            if let updater = controller?.updater,
               updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var previousActivationPolicy: NSApplication.ActivationPolicy?
    @ObservationIgnored var backgroundActivationPolicy: NSApplication.ActivationPolicy = .accessory
    @ObservationIgnored private let log = Logger(subsystem: AppModel.bundleID, category: "updates")

    func start() {
        guard controller == nil else { return }
        problem = UpdateConfiguration.problem(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:])
        guard problem == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        do {
            try controller.updater.start()
            self.controller = controller
            observations = [
                controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                    MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
                },
                controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                    MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
                },
            ]
        } catch {
            problem = "Updates could not start: \(error.localizedDescription)"
            log.error("Sparkle startup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if previousActivationPolicy == nil { previousActivationPolicy = NSApp.activationPolicy() }
        NSApp.setActivationPolicy(.regular)
        if !state.userInitiated { NSApp.dockTile.badgeLabel = "1" }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NSApp.dockTile.badgeLabel = ""
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.dockTile.badgeLabel = ""
        if previousActivationPolicy != nil { NSApp.setActivationPolicy(backgroundActivationPolicy) }
        previousActivationPolicy = nil
    }
}
