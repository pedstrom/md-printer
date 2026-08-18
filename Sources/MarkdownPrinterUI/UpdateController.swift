import Combine
import Foundation
import Sparkle

@MainActor
package protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var stateDidChange: (() -> Void)? { get set }

    func checkForUpdates()
}

@MainActor
public final class UpdateController: ObservableObject {
    @Published public private(set) var canCheckForUpdates: Bool

    public var automaticallyChecksForUpdates: Bool {
        get { updateChecker.automaticallyChecksForUpdates }
        set {
            guard newValue != updateChecker.automaticallyChecksForUpdates else { return }
            objectWillChange.send()
            updateChecker.automaticallyChecksForUpdates = newValue
        }
    }

    private let updateChecker: any UpdateChecking
    private let retainedDelegate: AnyObject?

    public convenience init(
        documentRestoration: OpenDocumentRestorationController,
        activityCoordinator: ApplicationActivityCoordinator
    ) {
        let delegate = SparkleInstallationDelegate(
            documentRestoration: documentRestoration,
            activityCoordinator: activityCoordinator
        )
        let updateChecker = SparkleUpdateChecker(delegate: delegate)
        self.init(updateChecker: updateChecker, retainedDelegate: delegate)
    }

    package init(updateChecker: any UpdateChecking, retainedDelegate: AnyObject? = nil) {
        self.updateChecker = updateChecker
        self.retainedDelegate = retainedDelegate
        canCheckForUpdates = updateChecker.canCheckForUpdates
        updateChecker.stateDidChange = { [weak self] in
            guard let self else { return }
            let newValue = self.updateChecker.canCheckForUpdates
            if newValue == self.canCheckForUpdates {
                self.objectWillChange.send()
            } else {
                self.canCheckForUpdates = newValue
            }
        }
    }

    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updateChecker.checkForUpdates()
    }
}

@MainActor
private final class SparkleUpdateChecker: NSObject, UpdateChecking {
    var stateDidChange: (() -> Void)?

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    private let updaterController: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    init(delegate: SPUUpdaterDelegate) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        super.init()

        observations = [
            updaterController.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                [weak self] _, _ in
                DispatchQueue.main.async { self?.stateDidChange?() }
            },
            updaterController.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) {
                [weak self] _, _ in
                DispatchQueue.main.async { self?.stateDidChange?() }
            }
        ]
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

@MainActor
package final class SparkleInstallationDelegate: NSObject, SPUUpdaterDelegate {
    private let documentRestoration: OpenDocumentRestorationController
    private let activityCoordinator: ApplicationActivityCoordinator

    init(
        documentRestoration: OpenDocumentRestorationController,
        activityCoordinator: ApplicationActivityCoordinator
    ) {
        self.documentRestoration = documentRestoration
        self.activityCoordinator = activityCoordinator
    }

    package func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        prepareForInstallation(targetBuild: item.versionString)
    }

    package func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeRelaunch(until: installHandler)
    }

    package func prepareForInstallation(targetBuild: String) {
        documentRestoration.prepareForRelaunch(targetBuild: targetBuild)
    }

    package func postponeRelaunch(until installHandler: @escaping () -> Void) -> Bool {
        activityCoordinator.postponeRelaunch(until: installHandler)
    }
}
