#if os(macOS)
import AppKit
#endif
import Combine
import Foundation
import Network
import OnlineStatusCore

/// A change of displayed status, kept for shading the graph.
/// The kind of network currently in use.
enum NetworkKind: Equatable {
    case wifi, ethernet, cellular, other, none
}

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

    var scheduleDescription: String {
        #if os(iOS)
        let label = "cellular"
        #else
        let label = "tethered"
        #endif
        let base = settings.scheduleDescription(onExpensiveNetwork: onExpensiveNetwork, expensiveLabel: label)
        guard isCheckingFaster, let fast = settings.fastProbeInterval(base: currentInterval) else { return base }
        return base + " (now every \(Int(fast)) s after a change)"
    }

    /// After the status changes, probe faster until this time.
    private var fastUntil: Date?

    private var isCheckingFaster: Bool {
        guard let fastUntil else { return false }
        return now() < fastUntil
    }

    /// Seconds to wait before the next probe: faster for a while after a change.
    private var nextProbeInterval: TimeInterval {
        if isCheckingFaster, let fast = settings.fastProbeInterval(base: currentInterval) {
            return fast
        }
        return currentInterval
    }

    private var history = SampleHistory(retention: 60 * 60)
    private var evaluator: StatusEvaluator
    /// The evaluator only looks at samples taken after this date (set when the network changes).
    private var epoch = Date.distantPast
    private var loopTask: Task<Void, Never>?

    private let pathMonitor = NWPathMonitor()
    private var pathSatisfied = true
    private var pathSignature: String?
    private var observers: [NSObjectProtocol] = []

    /// The current time. Screenshot mode freezes it so generated images don't change between runs.
    private(set) var now: () -> Date = { Date() }

    /// Screenshot mode: show `samples` (oldest first) as if they had just been measured,
    /// with the clock stopped at `frozenNow`. No probes run.
    func loadDemo(_ samples: [Sample], frozenNow: Date) {
        stopLoop()
        now = { frozenNow }
        history.removeAll()
        evaluator.reset()
        status = .measuring
        let start = samples.first?.date ?? frozenNow
        statusChanges = [StatusChange(date: start.addingTimeInterval(-10), status: .measuring)]
        for sample in samples {
            record(sample)
        }
    }

    /// The network in use, for the log.
    private(set) var networkKind: NetworkKind = .none
    /// Called after each probe with the sample and the resulting status.
    var onRecord: ((Sample, DisplayStatus) -> Void)?
    /// Called just before the Mac goes to sleep.
    var onSleep: (() -> Void)?

    init() {
        UserDefaults.standard.register(defaults: MonitorSettings.defaults)
        let settings = MonitorSettings(defaults: .standard)
        self.settings = settings
        self.evaluator = StatusEvaluator(configuration: settings.makeEvaluatorConfiguration(interval: settings.interval))
    }

    private var started = false

    /// Starts watching the network and probing. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSettings() }
        })
        #if os(macOS)
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        #endif

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            let signature = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
            let kind: NetworkKind
            if path.status != .satisfied {
                kind = .none
            } else if path.usesInterfaceType(.wifi) {
                kind = .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = .ethernet
            } else if path.usesInterfaceType(.cellular) {
                kind = .cellular
            } else {
                kind = .other
            }
            Task { @MainActor in
                self?.networkKind = kind
                self?.pathUpdated(satisfied: satisfied, expensive: expensive, signature: signature)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "OnlineStatus.path"))

        restartLoop()
    }

    /// Stop probing for now: the Mac is going to sleep, or the iOS app went to the background.
    func pause() {
        onSleep?()
        stopLoop()
    }

    /// Start again after `pause()`: judge afresh and probe right away.
    func resume() {
        guard started else { return start() }
        networkChanged()
    }

    /// Run a probe right away and continue the schedule from there.
    func probeNow() {
        restartLoop()
    }

    /// Statistics over the period shown in the graph.
    var recentSummary: SampleSummary {
        SampleSummary(history.samples(since: now().addingTimeInterval(-Self.graphSpan)))
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
        let scheduleChanged = newSettings.interval != settings.interval
            || newSettings.timeout != settings.timeout
            || newSettings.tetheredBackoff != settings.tetheredBackoff
            || newSettings.tetheredInterval != settings.tetheredInterval
        settings = newSettings
        evaluator.configuration = newSettings.makeEvaluatorConfiguration(interval: newSettings.probeInterval(onExpensiveNetwork: onExpensiveNetwork))
        if probeChanged {
            networkChanged()
        } else if scheduleChanged {
            restartLoop()
        }
        // Other settings (thresholds, pulse, log) take effect without an extra probe.
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func restartLoop() {
        stopLoop()
        let settings = self.settings
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
                let wait = Duration.milliseconds(Int64(self.nextProbeInterval * 1000)) - (clock.now - began)
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
        onRecord?(sample, newStatus)
    }

    private func publish(_ newStatus: DisplayStatus, at date: Date) {
        guard newStatus != status else { return }
        // A real change (not to or from "measuring"): check faster to see how long it lasts.
        if newStatus != .measuring && status != .measuring {
            fastUntil = date.addingTimeInterval(settings.fastDuration)
        }
        status = newStatus
        statusChanges.append(StatusChange(date: date, status: newStatus))
        // Keep the newest change that is older than the retention period, for shading.
        let cutoff = date.addingTimeInterval(-history.retention)
        if let index = statusChanges.lastIndex(where: { $0.date < cutoff }), index > 0 {
            statusChanges.removeFirst(index)
        }
    }
}
