import Foundation

enum SuccessfulUpdateCheckOutcome: String, Equatable {
    case noActionableUpdate
    case updateAvailable
}

protocol UpdateCheckHistoryStoring: AnyObject {
    var lastAutomaticCheckDate: Date? { get set }
    var lastSuccessfulAutomaticCheckOutcome:
        SuccessfulUpdateCheckOutcome? { get set }
}

final class UserDefaultsUpdateCheckHistoryStore:
    UpdateCheckHistoryStoring
{
    static let lastAutomaticCheckDateKey =
        "updates.lastAutomaticCheckDate"
    static let lastSuccessfulAutomaticCheckOutcomeKey =
        "updates.lastSuccessfulAutomaticCheckOutcome"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastAutomaticCheckDate: Date? {
        get {
            defaults.object(
                forKey: Self.lastAutomaticCheckDateKey
            ) as? Date
        }
        set {
            if let newValue {
                defaults.set(
                    newValue,
                    forKey: Self.lastAutomaticCheckDateKey
                )
            } else {
                defaults.removeObject(
                    forKey: Self.lastAutomaticCheckDateKey
                )
            }
        }
    }

    var lastSuccessfulAutomaticCheckOutcome:
        SuccessfulUpdateCheckOutcome?
    {
        get {
            defaults.string(
                forKey: Self.lastSuccessfulAutomaticCheckOutcomeKey
            ).flatMap(SuccessfulUpdateCheckOutcome.init(rawValue:))
        }
        set {
            if let newValue {
                defaults.set(
                    newValue.rawValue,
                    forKey: Self.lastSuccessfulAutomaticCheckOutcomeKey
                )
            } else {
                defaults.removeObject(
                    forKey: Self.lastSuccessfulAutomaticCheckOutcomeKey
                )
            }
        }
    }
}

@MainActor
protocol AutomaticUpdateCheckScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    )
    func cancel()
}

@MainActor
final class TaskAutomaticUpdateCheckScheduler:
    AutomaticUpdateCheckScheduling
{
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let sleeper: Sleeper
    private var task: Task<Void, Never>?

    init(
        sleeper: @escaping Sleeper = { duration in
            try await Task<Never, Never>.sleep(for: duration)
        }
    ) {
        self.sleeper = sleeper
    }

    deinit {
        task?.cancel()
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        precondition(delay.isFinite && delay >= 0)
        cancel()

        let sleeper = sleeper
        let nanoseconds = Int64(
            (delay * 1_000_000_000).rounded(.up)
        )
        task = Task { @MainActor [weak self] in
            do {
                try await sleeper(.nanoseconds(nanoseconds))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
