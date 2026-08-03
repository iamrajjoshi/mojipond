import Combine
import Foundation
import Sparkle

@MainActor
protocol SparkleUpdaterDriving: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }

    func start()
    func checkForUpdates()
    func observeCanCheckForUpdates(
        _ handler: @escaping @MainActor (Bool) -> Void
    )
}

@MainActor
final class SystemSparkleUpdaterDriver: SparkleUpdaterDriving {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var canCheckForUpdatesObservation: AnyCancellable?

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func observeCanCheckForUpdates(
        _ handler: @escaping @MainActor (Bool) -> Void
    ) {
        canCheckForUpdatesObservation = controller.updater.publisher(
            for: \.canCheckForUpdates,
            options: [.initial, .new]
        )
        .receive(on: RunLoop.main)
        .sink { @MainActor value in
            handler(value)
        }
    }
}

struct SparkleUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL?
    let publicKey: Data?

    var isConfigured: Bool {
        feedURL?.scheme?.lowercased() == "https"
            && feedURL?.host?.isEmpty == false
            && feedURL?.user == nil
            && feedURL?.password == nil
            && publicKey?.count == 32
    }

    static func load(bundle: Bundle = .main) -> SparkleUpdateConfiguration {
        let feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
            .flatMap(URL.init(string:))
        let publicKey = (
            bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        ).flatMap { Data(base64Encoded: $0) }
        return SparkleUpdateConfiguration(
            feedURL: feedURL,
            publicKey: publicKey
        )
    }
}

@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var automaticChecksEnabled = false
    @Published private(set) var canCheckForUpdates = false

    let isConfigured: Bool

    private let driver: any SparkleUpdaterDriving
    private var hasStarted = false
    private var observesAvailability = false

    init(
        configuration: SparkleUpdateConfiguration = .load(),
        driver: (any SparkleUpdaterDriving)? = nil
    ) {
        isConfigured = configuration.isConfigured
        self.driver = driver ?? SystemSparkleUpdaterDriver()
    }

    var statusSummary: String {
        automaticChecksEnabled
            ? "Checks daily and asks before installing"
            : "Manual update checks"
    }

    func start() {
        guard isConfigured else {
            return
        }
        startIfNeeded()
        observeAvailabilityIfNeeded()
        automaticChecksEnabled = driver.automaticallyChecksForUpdates
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard isConfigured else {
            return
        }
        startIfNeeded()
        observeAvailabilityIfNeeded()
        driver.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = driver.automaticallyChecksForUpdates
    }

    func checkManually() {
        guard isConfigured else {
            return
        }
        startIfNeeded()
        observeAvailabilityIfNeeded()
        guard canCheckForUpdates else {
            return
        }
        driver.checkForUpdates()
    }

    private func startIfNeeded() {
        guard !hasStarted else {
            return
        }
        driver.start()
        hasStarted = true
    }

    private func observeAvailabilityIfNeeded() {
        guard !observesAvailability else {
            return
        }
        observesAvailability = true
        driver.observeCanCheckForUpdates { [weak self] canCheck in
            self?.canCheckForUpdates = canCheck
        }
        canCheckForUpdates = driver.canCheckForUpdates
    }
}
