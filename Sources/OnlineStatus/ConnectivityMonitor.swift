import AppKit
import Combine
import Foundation
import Network
import OnlineStatusCore

/// A change of displayed status, kept for shading the graph.
struct StatusChange: Equatable {
    var date: Date
    var status: DisplayStatus
}

/// Runs probes on a schedule and turns the results into a status.
@MainActor
final class ConnectivityMonitor: ObservableObject {
    /// How much history the graph can show.
    static let graphSpan: TimeInterval = 5 * 60

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var status: DisplayStatus = .measuring
    @Published private(set) var statusChanges: [StatusChange] = [StatusChange(date: Date(), status: .measuring)]
    @Published private(set) var settings: MonitorSettings
    /// The current network is a personal hotspot / tether, or Low Data Mode is on.
    @Published private(set) var onExpensiveNetwork = false

    /// Seconds between probes right now.
    var currentInterval: TimeInterval { settings.probeInterval(onExpensiveNetwork: onExpensiveNetwork) }

    var scheduleDescription: String { settings.scheduleDescription(onExpensiveNetwork: onExpensiveNetwork) }

    private var history = SampleHistory(retention: 60 * 60)
    private var evaluator: StatusEvaluator
    /// The evaluator only looks at samples taken after this date (set when the network changes).
    private var epoch = Date.distantPast
    private var loopTask: Task<Void, Never>?

    private let pathMonitor = NWPathMonitor()
    private var pathSatisfied = true
    private var pathSignature: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        UserDefaults.standard.register(defaults: MonitorSettings.defaults)
        let settings = MonitorSettings(defaults: .standard)
        self.settings = settings
        self.evaluator = StatusEvaluator(configuration: settings.makeEvaluatorConfiguration(interval: settings.interval))
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSettings() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopLoop() }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.networkChanged() }
        })

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            let signature = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in self?.pathUpdated(satisfied: satisfied, expensive: expensive, signature: signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "OnlineStatus.path"))

        restartLoop()
    }

    /// Run a probe right away and continue the schedule from there.
    func probeNow() {
        restartLoop()
    }

    /// Statistics over the period shown in the graph.
    var recentSummary: SampleSummary {
        SampleSummary(history.samples(since: Date().addingTimeInterval(-Self.graphSpan)))
    }

    // MARK: - Private

    private func pathUpdated(satisfied: Bool, expensive: Bool, signature: String) {
        let first = pathSignature == nil
        let expensiveChanged = expensive != onExpensiveNetwork
        onExpensiveNetwork = expensive
        evaluator.configuration = settings.makeEvaluatorConfiguration(interval: currentInterval)
        if signature != pathSignature {
            pathSignature = signature
            pathSatisfied = satisfied
            if !first {
                networkChanged()
                return
            }
        }
        // Same interfaces, but e.g. Low Data Mode was toggled: pick up the new interval.
        if expensiveChanged && settings.tetheredBackoff { restartLoop() }
    }

    /// Start judging afresh: old samples stay on the graph but no longer count.
    private func networkChanged() {
        epoch = Date()
        evaluator.reset()
        publish(evaluator.status, at: epoch)
        restartLoop()
    }

    private func reloadSettings() {
        let newSettings = MonitorSettings(defaults: .standard)
        guard newSettings != settings else { return }
        let probeChanged = newSettings.mode != settings.mode
            || newSettings.pingHost != settings.pingHost
            || newSettings.url != settings.url
            || newSettings.httpExpectation != settings.httpExpectation
        settings = newSettings
        evaluator.configuration = newSettings.makeEvaluatorConfiguration(interval: newSettings.probeInterval(onExpensiveNetwork: onExpensiveNetwork))
        if probeChanged {
            networkChanged()
        } else {
            restartLoop()
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func restartLoop() {
        stopLoop()
        let settings = self.settings
        let interval = currentInterval
        let probe = makeProbe(for: settings)
        loopTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let began = clock.now
                let sample: Sample
                if self?.pathSatisfied == false {
                    sample = .failure(at: Date(), .noPath)
                } else {
                    sample = await probe.run()
                }
                guard !Task.isCancelled, let self else { return }
                self.record(sample)
                let wait = Duration.milliseconds(Int64(interval * 1000)) - (clock.now - began)
                if wait > .zero {
                    try? await Task.sleep(for: wait)
                }
            }
        }
    }

    private func record(_ sample: Sample) {
        history.append(sample)
        samples = history.samples
        let considered = history.samples(since: epoch)
        let newStatus = evaluator.evaluate(considered, now: sample.date)
        publish(newStatus, at: sample.date)
    }

    private func publish(_ newStatus: DisplayStatus, at date: Date) {
        guard newStatus != status else { return }
        status = newStatus
        statusChanges.append(StatusChange(date: date, status: newStatus))
        // Keep the newest change that is older than the retention period, for shading.
        let cutoff = date.addingTimeInterval(-history.retention)
        if let index = statusChanges.lastIndex(where: { $0.date < cutoff }), index > 0 {
            statusChanges.removeFirst(index)
        }
    }
}
