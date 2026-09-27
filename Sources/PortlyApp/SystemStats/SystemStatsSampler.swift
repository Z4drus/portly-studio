import Foundation

/// The cards the "This Mac" grid can show, in display order.
enum SystemCardKind: Hashable, Sendable {
    case cpu
    case memory
    case gpu
    case network
    case disk
    case thermals
    case power
}

/// Two rates that belong together: download/upload, read/write.
struct PairedRate: Equatable, Sendable {
    let primary: Double
    let secondary: Double

    static let zero = PairedRate(primary: 0, secondary: 0)

    var larger: Double { max(primary, secondary) }
}

struct SystemSummary: Equatable, Sendable {
    let chipName: String?
    let coreSummary: String
    let memoryBytes: UInt64
    let osVersion: String
}

struct CPUCardState: Equatable, Sendable {
    let description: CPUDescription
    let current: CPUReading?
    let loadAverage: [Double]?
    let uptime: TimeInterval?
    let history: [TimedSample<CPUUsage>]
    let windowEnd: Date
}

struct MemoryCardState: Equatable, Sendable {
    let current: MemoryReading
    let history: [TimedSample<MemoryBreakdown>]
    let windowEnd: Date
}

struct GPUCardState: Equatable, Sendable {
    let description: GPUDescription
    let current: GPUReading
    let history: [TimedSample<Double>]
    let windowEnd: Date
}

struct NetworkCardState: Equatable, Sendable {
    /// Download (primary) and upload (secondary), bytes per second.
    let current: PairedRate?
    let peak: PairedRate
    let totalReceived: UInt64
    let totalSent: UInt64
    /// Interfaces that carried traffic since sampling began, busiest first.
    let interfaces: [String]
    let history: [TimedSample<PairedRate>]
    let axisCeiling: Double
    let windowEnd: Date
}

struct DiskCardState: Equatable, Sendable {
    /// Read (primary) and write (secondary), bytes per second.
    let current: PairedRate?
    /// Read and write operations per second.
    let operations: PairedRate?
    let totalRead: UInt64
    let totalWritten: UInt64
    let volume: VolumeCapacity?
    let history: [TimedSample<PairedRate>]
    let axisCeiling: Double
    let windowEnd: Date
}

struct ThermalCardState: Equatable, Sendable {
    let current: ThermalSummary
    let thermalState: SystemThermalState?
    let history: [TimedSample<ThermalSummary>]
    let axisRange: ClosedRange<Double>
    let windowEnd: Date
}

struct PowerCardState: Equatable, Sendable {
    let current: PowerReading
    /// Whole-machine power draw, watts. Empty when the Mac does not report it.
    let history: [TimedSample<Double>]
    let axisCeiling: Double
    let windowEnd: Date
}

/// Everything one sampling pass produced, ready to publish.
struct SystemStatsFrame: Sendable {
    var cards: [SystemCardKind] = []
    var summary: SystemSummary?
    var cpu: CPUCardState?
    var memory: MemoryCardState?
    var gpu: GPUCardState?
    var network: NetworkCardState?
    var disk: DiskCardState?
    var thermals: ThermalCardState?
    var power: PowerCardState?
}

/// Owns the readers and the histories. Confined to the model's utility queue:
/// every method runs there, never on the main thread.
final class SystemStatsSampler {
    static let interval: TimeInterval = 1
    static let window: TimeInterval = 120

    /// Slow-moving sources are read on a coarser cadence (in ticks).
    private static let powerCadence = 2
    private static let thermalCadence = 3
    private static let volumeCadence = 30
    private static let gpuRetryCadence = 10

    /// Deltas beyond these are counter jumps, not traffic.
    private static let networkCeiling64 = 12_500_000_000.0 // 100 Gb/s
    private static let networkCeiling32 = 1_250_000_000.0 // 10 Gb/s keeps 32-bit resets out
    private static let diskCeiling = 50_000_000_000.0
    private static let operationsCeiling = 10_000_000.0

    private let cpuReader = CPUStatsReader()
    private let memoryReader = MemoryStatsReader()
    private let gpuReader = GPUStatsReader()
    private let networkReader = NetworkStatsReader()
    private let diskReader = DiskStatsReader()
    private let powerReader = PowerStatsReader()
    private let thermalReader = ThermalSensorReader()

    private var cpuDescription: CPUDescription?
    private var gpuDescription: GPUDescription?
    private var thermalsAvailable = false
    private var summary: SystemSummary?

    private var sequence = 0
    private var segment = 0
    private var tick = 0
    private var resumePending = true
    private var lastSampleDate: Date?
    private var lastSampleUptime: TimeInterval?

    private var cpuHistory = RingBuffer<TimedSample<CPUUsage>>(capacity: SystemStatsSampler.capacity(cadence: 1))
    private var memoryHistory = RingBuffer<TimedSample<MemoryBreakdown>>(capacity: SystemStatsSampler.capacity(cadence: 1))
    private var gpuHistory = RingBuffer<TimedSample<Double>>(capacity: SystemStatsSampler.capacity(cadence: 1))
    private var networkHistory = RingBuffer<TimedSample<PairedRate>>(capacity: SystemStatsSampler.capacity(cadence: 1))
    private var diskHistory = RingBuffer<TimedSample<PairedRate>>(capacity: SystemStatsSampler.capacity(cadence: 1))
    private var thermalHistory = RingBuffer<TimedSample<ThermalSummary>>(
        capacity: SystemStatsSampler.capacity(cadence: SystemStatsSampler.thermalCadence)
    )
    private var powerHistory = RingBuffer<TimedSample<Double>>(
        capacity: SystemStatsSampler.capacity(cadence: SystemStatsSampler.powerCadence)
    )

    private var lastCPU: CPUReading?
    private var lastMemory: MemoryReading?
    private var lastGPU: GPUReading?
    private var gpuMisses = 0

    private var networkBaseline: NetworkCounters?
    private var lastNetworkRate: PairedRate?
    private var totalReceived: UInt64 = 0
    private var totalSent: UInt64 = 0
    private var trafficByInterface: [String: UInt64] = [:]
    private var networkAxis: Double?

    private var diskBaseline: DiskCounters?
    private var lastDiskRate: PairedRate?
    private var lastDiskOperations: PairedRate?
    private var totalRead: UInt64 = 0
    private var totalWritten: UInt64 = 0
    private var volume: VolumeCapacity?
    private var diskAxis: Double?

    private var lastThermal: ThermalSummary?
    private var lastPower: PowerReading?
    private var lastPowerDate: Date?
    private var powerAxis: Double?

    /// Enough samples to cover the window plus the one that enters from the left.
    private static func capacity(cadence: Int) -> Int {
        Int((window / (interval * Double(cadence))).rounded(.up)) + 3
    }

    // MARK: - Lifecycle

    /// Called whenever sampling (re)starts. Probes what this Mac offers, primes
    /// the delta baselines and returns a first frame with every instantaneous
    /// metric already filled in.
    func start(now: Date, uptime: TimeInterval) -> SystemStatsFrame {
        if cpuDescription == nil {
            cpuDescription = CPUStatsReader.describe()
        }
        gpuDescription = gpuReader.prepare()
        gpuMisses = 0
        powerReader.prepare()
        thermalsAvailable = thermalReader.prepare()
        if summary == nil, let cpuDescription {
            summary = Self.makeSummary(cpu: cpuDescription)
        }
        cpuReader.resetBaseline()
        resumePending = true
        tick = 0
        return sample(now: now, uptime: uptime)
    }

    /// Releases the IOKit handles. Histories and totals survive, so a window
    /// that comes back into view picks up where it left off.
    func stop() {
        gpuReader.release()
        powerReader.release()
        thermalReader.release()
    }

    // MARK: - Sampling

    func sample(now: Date, uptime: TimeInterval) -> SystemStatsFrame {
        let elapsed = lastSampleUptime.map { uptime - $0 } ?? 0
        let wallElapsed = lastSampleDate.map { now.timeIntervalSince($0) } ?? 0
        let isContinuous = !resumePending
            && !SampleTiming.isGap(elapsed: elapsed, interval: Self.interval)
            && !SampleTiming.isGap(elapsed: wallElapsed, interval: Self.interval)
        if !isContinuous {
            // Whatever comes next belongs to a new line on every chart.
            segment += 1
        }
        resumePending = false
        lastSampleUptime = uptime
        lastSampleDate = now
        sequence += 1
        defer { tick += 1 }

        sampleCPU(now: now, isContinuous: isContinuous)
        sampleMemory(now: now)
        sampleGPU(now: now)
        sampleNetwork(now: now, elapsed: elapsed, isContinuous: isContinuous)
        sampleDisk(now: now, elapsed: elapsed, isContinuous: isContinuous)
        if tick % Self.thermalCadence == 0 {
            sampleThermals(now: now)
        }
        if tick % Self.powerCadence == 0 {
            samplePower(now: now)
        }
        return makeFrame(now: now)
    }

    private func sampleCPU(now: Date, isContinuous: Bool) {
        guard let reading = cpuReader.read() else { return }
        lastCPU = reading
        if isContinuous {
            cpuHistory.append(TimedSample(id: sequence, date: now, segment: segment, value: reading.usage))
        }
    }

    private func sampleMemory(now: Date) {
        guard let reading = memoryReader.read() else { return }
        lastMemory = reading
        memoryHistory.append(TimedSample(id: sequence, date: now, segment: segment, value: reading.breakdown))
    }

    private func sampleGPU(now: Date) {
        if gpuDescription == nil {
            // A GPU that was powered down or not yet published may show up later.
            if tick % Self.gpuRetryCadence == 0, tick > 0 {
                gpuDescription = gpuReader.prepare()
            }
            guard gpuDescription != nil else { return }
        }
        guard let reading = gpuReader.read() else {
            gpuMisses += 1
            if gpuMisses >= 5 {
                gpuDescription = gpuReader.prepare()
                gpuMisses = 0
            }
            return
        }
        gpuMisses = 0
        lastGPU = reading
        gpuHistory.append(TimedSample(id: sequence, date: now, segment: segment, value: reading.deviceUtilization))
    }

    private func sampleNetwork(now: Date, elapsed: TimeInterval, isContinuous: Bool) {
        guard let counters = networkReader.read() else { return }
        defer { networkBaseline = counters }
        // The last rate stays on screen until a continuous pair of readings
        // replaces it, so a card never flashes back to "Collecting…".
        guard let baseline = networkBaseline, baseline.bitWidth == counters.bitWidth else { return }
        let ceiling = RateMath.plausibleCeiling(
            bytesPerSecond: counters.bitWidth == 64 ? Self.networkCeiling64 : Self.networkCeiling32,
            elapsed: max(elapsed, Self.interval)
        )
        let received = CounterMath.deltas(
            previous: baseline.received, current: counters.received, bitWidth: counters.bitWidth, ceiling: ceiling
        )
        let sent = CounterMath.deltas(
            previous: baseline.sent, current: counters.sent, bitWidth: counters.bitWidth, ceiling: ceiling
        )
        let receivedTotal = received.values.reduce(0, +)
        let sentTotal = sent.values.reduce(0, +)
        // Totals include traffic that happened while the view was hidden.
        totalReceived += receivedTotal
        totalSent += sentTotal
        for (name, bytes) in received.merging(sent, uniquingKeysWith: +) where bytes > 0 {
            trafficByInterface[name, default: 0] += bytes
        }

        guard isContinuous else { return }
        let rate = PairedRate(
            primary: RateMath.perSecond(receivedTotal, over: elapsed),
            secondary: RateMath.perSecond(sentTotal, over: elapsed)
        )
        lastNetworkRate = rate
        networkHistory.append(TimedSample(id: sequence, date: now, segment: segment, value: rate))
    }

    private func sampleDisk(now: Date, elapsed: TimeInterval, isContinuous: Bool) {
        if volume == nil || tick % Self.volumeCadence == 0 {
            volume = DiskStatsReader.bootVolume() ?? volume
        }
        guard let counters = diskReader.read() else { return }
        defer { diskBaseline = counters }
        guard let baseline = diskBaseline else { return }
        let span = max(elapsed, Self.interval)
        let bytesCeiling = RateMath.plausibleCeiling(bytesPerSecond: Self.diskCeiling, elapsed: span)
        let operationsCeiling = RateMath.plausibleCeiling(bytesPerSecond: Self.operationsCeiling, elapsed: span)
        let read = CounterMath.summedDelta(
            previous: baseline.bytesRead, current: counters.bytesRead, bitWidth: 64, ceiling: bytesCeiling
        )
        let written = CounterMath.summedDelta(
            previous: baseline.bytesWritten, current: counters.bytesWritten, bitWidth: 64, ceiling: bytesCeiling
        )
        totalRead += read
        totalWritten += written

        guard isContinuous else { return }
        let readOperations = CounterMath.summedDelta(
            previous: baseline.readOperations, current: counters.readOperations, bitWidth: 64, ceiling: operationsCeiling
        )
        let writeOperations = CounterMath.summedDelta(
            previous: baseline.writeOperations, current: counters.writeOperations, bitWidth: 64, ceiling: operationsCeiling
        )
        let rate = PairedRate(
            primary: RateMath.perSecond(read, over: elapsed),
            secondary: RateMath.perSecond(written, over: elapsed)
        )
        lastDiskRate = rate
        lastDiskOperations = PairedRate(
            primary: RateMath.perSecond(readOperations, over: elapsed),
            secondary: RateMath.perSecond(writeOperations, over: elapsed)
        )
        diskHistory.append(TimedSample(id: sequence, date: now, segment: segment, value: rate))
    }

    private func sampleThermals(now: Date) {
        guard thermalsAvailable else { return }
        guard let summary = thermalReader.read() else {
            if thermalReader.isDisabled {
                thermalsAvailable = false
                lastThermal = nil
            }
            return
        }
        lastThermal = summary
        thermalHistory.append(TimedSample(id: sequence, date: now, segment: segment, value: summary))
    }

    private func samplePower(now: Date) {
        let reading = powerReader.read()
        if reading != lastPower {
            lastPower = reading
            lastPowerDate = now
        }
        if let watts = reading.systemWatts {
            powerHistory.append(TimedSample(id: sequence, date: now, segment: segment, value: watts))
        }
    }

    // MARK: - Frame

    private func makeFrame(now: Date) -> SystemStatsFrame {
        var frame = SystemStatsFrame()
        frame.summary = summary
        frame.cards = [.cpu, .memory]
        if gpuDescription != nil { frame.cards.append(.gpu) }
        frame.cards += [.network, .disk]
        if thermalsAvailable { frame.cards.append(.thermals) }
        frame.cards.append(.power)

        if let cpuDescription {
            let history = visible(cpuHistory, fallbackEnd: now)
            frame.cpu = CPUCardState(
                description: cpuDescription,
                current: lastCPU,
                loadAverage: CPUStatsReader.loadAverage(),
                uptime: CPUStatsReader.uptime(now: now),
                history: history.samples,
                windowEnd: history.end
            )
        }

        if let lastMemory {
            let history = visible(memoryHistory, fallbackEnd: now)
            frame.memory = MemoryCardState(current: lastMemory, history: history.samples, windowEnd: history.end)
        }

        if let gpuDescription, let lastGPU {
            let history = visible(gpuHistory, fallbackEnd: now)
            frame.gpu = GPUCardState(
                description: gpuDescription,
                current: lastGPU,
                history: history.samples,
                windowEnd: history.end
            )
        }

        let network = visible(networkHistory, fallbackEnd: now)
        let networkPeak = Self.peak(of: network.samples)
        networkAxis = AxisScale.stableCeiling(peak: networkPeak.larger, previous: networkAxis, minimum: 100_000)
        frame.network = NetworkCardState(
            current: lastNetworkRate,
            peak: networkPeak,
            totalReceived: totalReceived,
            totalSent: totalSent,
            interfaces: trafficByInterface
                .sorted { $0.value > $1.value }
                .map { networkReader.displayName(for: $0.key) },
            history: network.samples,
            axisCeiling: networkAxis ?? 100_000,
            windowEnd: network.end
        )

        let disk = visible(diskHistory, fallbackEnd: now)
        diskAxis = AxisScale.stableCeiling(peak: Self.peak(of: disk.samples).larger, previous: diskAxis, minimum: 1_000_000)
        frame.disk = DiskCardState(
            current: lastDiskRate,
            operations: lastDiskOperations,
            totalRead: totalRead,
            totalWritten: totalWritten,
            volume: volume,
            history: disk.samples,
            axisCeiling: diskAxis ?? 1_000_000,
            windowEnd: disk.end
        )

        if thermalsAvailable, let lastThermal {
            let history = visible(thermalHistory, fallbackEnd: now)
            let hottest = history.samples.map(\.value.hottestDie).max() ?? lastThermal.hottestDie
            frame.thermals = ThermalCardState(
                current: lastThermal,
                thermalState: lastPower?.thermalState,
                history: history.samples,
                axisRange: AxisScale.temperatureRange(peak: hottest),
                windowEnd: history.end
            )
        }

        if let lastPower {
            // Without a power history (desktop Macs) the window must not move
            // every second, or an unchanged card would republish each tick.
            let history = visible(powerHistory, fallbackEnd: lastPowerDate ?? now)
            powerAxis = AxisScale.stableCeiling(
                peak: history.samples.map(\.value).max() ?? 0,
                previous: powerAxis,
                minimum: 10
            )
            frame.power = PowerCardState(
                current: lastPower,
                history: history.samples,
                axisCeiling: powerAxis ?? 10,
                windowEnd: history.end
            )
        }
        return frame
    }

    /// The samples inside the chart window, which ends at the newest sample so
    /// every chart's latest point sits on its right edge.
    private func visible<Value>(
        _ buffer: RingBuffer<TimedSample<Value>>,
        fallbackEnd: Date
    ) -> (samples: [TimedSample<Value>], end: Date) {
        let end = buffer.last?.date ?? fallbackEnd
        let samples = HistoryWindow.visible(buffer.elements, since: end.addingTimeInterval(-Self.window))
        return (samples, end)
    }

    private static func peak(of samples: [TimedSample<PairedRate>]) -> PairedRate {
        samples.reduce(PairedRate.zero) { peak, sample in
            PairedRate(
                primary: max(peak.primary, sample.value.primary),
                secondary: max(peak.secondary, sample.value.secondary)
            )
        }
    }

    private static func makeSummary(cpu: CPUDescription) -> SystemSummary {
        let coreSummary: String
        if cpu.groups.count > 1 {
            coreSummary = cpu.groups
                .map { "\($0.coreIndices.count)\($0.name.prefix(1).uppercased())" }
                .joined(separator: " + ") + " cores"
        } else {
            coreSummary = "\(cpu.logicalCPUCount) cores"
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = version.patchVersion > 0
            ? "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "macOS \(version.majorVersion).\(version.minorVersion)"
        return SystemSummary(
            chipName: cpu.chipName,
            coreSummary: coreSummary,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            osVersion: osVersion
        )
    }
}
