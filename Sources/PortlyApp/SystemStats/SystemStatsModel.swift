import Combine
import Foundation

/// One card's latest state. Each card observes only its own feed, and a feed
/// publishes only when its value actually changed, so a slow card (power,
/// temperatures) does not redraw on every CPU tick.
final class SystemStatsFeed<Value: Equatable>: ObservableObject {
    @Published private(set) var state: Value?

    func publish(_ newState: Value?) {
        guard newState != state else { return }
        state = newState
    }
}

/// Live, Mac-wide health numbers for the "This Mac" section.
///
/// Observed only by that section and its cards, never by `Supervisor` or the
/// main window (see `ResourceMonitor` for why that matters). Sampling happens
/// on a utility-QoS serial queue once a second and results are published on
/// the main thread; nothing runs unless the section is on screen, and `stop()`
/// releases every IOKit handle.
final class SystemStatsModel: ObservableObject {
    /// Changes only when a card appears or disappears.
    @Published private(set) var cards: [SystemCardKind] = []
    @Published private(set) var summary: SystemSummary?

    let cpu = SystemStatsFeed<CPUCardState>()
    let memory = SystemStatsFeed<MemoryCardState>()
    let gpu = SystemStatsFeed<GPUCardState>()
    let network = SystemStatsFeed<NetworkCardState>()
    let disk = SystemStatsFeed<DiskCardState>()
    let thermals = SystemStatsFeed<ThermalCardState>()
    let power = SystemStatsFeed<PowerCardState>()

    private let queue = DispatchQueue(label: "dev.portly.studio.system-stats", qos: .utility)
    /// Touched only on `queue`.
    private let sampler = SystemStatsSampler()
    private var timer: DispatchSourceTimer?
    /// Bumped on every start and stop, so a frame sampled before a stop can
    /// never land after it.
    private var generation = 0

    var isSampling: Bool { timer != nil }

    deinit {
        timer?.cancel()
        let sampler = self.sampler
        queue.async { sampler.stop() }
    }

    /// Starts sampling. Main thread only; idempotent.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }
        generation += 1
        let generation = self.generation
        let sampler = self.sampler

        queue.async { [weak self] in
            let frame = sampler.start(now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async { self?.apply(frame, generation: generation) }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = SystemStatsSampler.interval
        // The first rates need two readings; half a second is enough to
        // compare them, so the cards leave "Collecting…" sooner.
        timer.schedule(deadline: .now() + interval / 2, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            let frame = sampler.sample(now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async { self?.apply(frame, generation: generation) }
        }
        timer.resume()
        self.timer = timer
    }

    /// Stops sampling and releases the readers' system handles. Main thread
    /// only; idempotent.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        generation += 1
        let sampler = self.sampler
        queue.async { sampler.stop() }
    }

    private func apply(_ frame: SystemStatsFrame, generation: Int) {
        guard generation == self.generation else { return }
        if cards != frame.cards { cards = frame.cards }
        if summary != frame.summary { summary = frame.summary }
        cpu.publish(frame.cpu)

        // A chart update costs a few milliseconds of main-thread work; landing
        // all seven in one transaction would drop frames once a second while
        // the dashboard scrolls. Spread over separate run-loop turns, each
        // commit fits comfortably inside a frame.
        let deferred: [() -> Void] = [
            { [memory] in memory.publish(frame.memory) },
            { [gpu] in gpu.publish(frame.gpu) },
            { [network] in network.publish(frame.network) },
            { [disk] in disk.publish(frame.disk) },
            { [thermals] in thermals.publish(frame.thermals) },
            { [power] in power.publish(frame.power) },
        ]
        for (index, publish) in deferred.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishStagger * Double(index + 1)) { [weak self] in
                guard let self, generation == self.generation else { return }
                publish()
            }
        }
    }

    private static let publishStagger: TimeInterval = 0.06
}
