import Foundation

// Pure arithmetic behind the "This Mac" cards. Nothing here touches the
// system, so every rule (tick deltas, counter wraparound, rate math, axis
// scaling) is unit-tested on its own.

// MARK: - Ring buffer

/// A fixed-capacity FIFO: appending past capacity overwrites the oldest
/// element, so a history never grows beyond its window.
struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    /// Index of the oldest element once the storage is full.
    private var head = 0

    init(capacity: Int) {
        precondition(capacity > 0, "a ring buffer needs room for at least one element")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    /// Oldest first.
    var elements: [Element] {
        guard head != 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

extension RingBuffer: Equatable where Element: Equatable {
    static func == (lhs: RingBuffer, rhs: RingBuffer) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elements == rhs.elements
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

// MARK: - Timed samples

/// One point of a live history. `id` is a monotonically increasing sample
/// number (stable chart identity); `segment` changes whenever sampling paused,
/// so a chart never draws a line across time it did not observe.
struct TimedSample<Value: Equatable>: Equatable, Identifiable {
    let id: Int
    let date: Date
    let segment: Int
    let value: Value
}

extension TimedSample: Sendable where Value: Sendable {}

enum HistoryWindow {
    /// The samples a chart spanning `start...` needs: everything from `start`
    /// on, plus the last earlier sample of the same run so the line enters from
    /// the left edge instead of starting mid-plot.
    static func visible<Value>(_ samples: [TimedSample<Value>], since start: Date) -> [TimedSample<Value>] {
        guard let firstInside = samples.firstIndex(where: { $0.date >= start }) else { return [] }
        if firstInside > 0, samples[firstInside - 1].segment == samples[firstInside].segment {
            return Array(samples[(firstInside - 1)...])
        }
        return Array(samples[firstInside...])
    }
}

enum SampleTiming {
    /// A sample that arrives much later than scheduled (the Mac slept, the
    /// window was hidden) starts a new chart segment and yields no rate.
    static func isGap(elapsed: TimeInterval, interval: TimeInterval) -> Bool {
        elapsed <= 0 || elapsed > interval * 3
    }
}

// MARK: - CPU

/// Cumulative scheduler ticks of one logical CPU, as `host_processor_info`
/// reports them. The kernel counters are 32-bit and wrap.
struct CPUTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Fractions of the elapsed ticks, each in 0...1.
struct CPUUsage: Equatable, Sendable {
    let user: Double
    let system: Double
    let idle: Double

    var total: Double { user + system }
}

enum CPULoadMath {
    /// Usage between two readings of one core. Nice time counts as user time,
    /// as `top` and Activity Monitor do. Wrapping subtraction absorbs a counter
    /// that rolled over between the two readings.
    static func usage(from previous: CPUTicks, to current: CPUTicks) -> CPUUsage? {
        combined(previous: [previous], current: [current])
    }

    /// Whole-machine usage: every core's deltas summed, so a busy core weighs
    /// exactly as much as it should. Nil when the core count changed or no time
    /// elapsed.
    static func combined(previous: [CPUTicks], current: [CPUTicks]) -> CPUUsage? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        for (before, after) in zip(previous, current) {
            user += UInt64(after.user &- before.user) + UInt64(after.nice &- before.nice)
            system += UInt64(after.system &- before.system)
            idle += UInt64(after.idle &- before.idle)
        }
        let total = user + system + idle
        guard total > 0 else { return nil }
        return CPUUsage(
            user: Double(user) / Double(total),
            system: Double(system) / Double(total),
            idle: Double(idle) / Double(total)
        )
    }

    /// Busy fraction per core, in logical CPU order. Empty when the core count
    /// changed; a core that recorded no ticks reads as idle.
    static func perCore(previous: [CPUTicks], current: [CPUTicks]) -> [Double] {
        guard previous.count == current.count else { return [] }
        return zip(previous, current).map { before, after in
            usage(from: before, to: after).map { min(1, $0.total) } ?? 0
        }
    }
}

/// A group of cores of one kind ("Performance", "Efficiency"), in the order
/// macOS numbers its performance levels: fastest first.
struct CPUCoreGroup: Equatable, Sendable {
    let name: String
    let coreIndices: [Int]
}

enum CPUTopologyMath {
    struct PerformanceLevel: Equatable, Sendable {
        let name: String
        let logicalCPUCount: Int
    }

    /// Maps logical CPUs to performance levels.
    ///
    /// `levels` comes from `hw.perflevelN` (level 0 is the fastest), and
    /// `clusterTypes` maps a logical CPU id to its device-tree `cluster-type`
    /// letter. A letter is matched to a level only when its core count is
    /// unambiguous; anything less than a clean, complete match falls back to a
    /// single group, because a wrong split is worse than none.
    static func groups(
        levels: [PerformanceLevel],
        clusterTypes: [Int: String],
        logicalCPUCount: Int
    ) -> [CPUCoreGroup] {
        let everything = [CPUCoreGroup(name: "Cores", coreIndices: Array(0..<max(0, logicalCPUCount)))]
        guard levels.count > 1,
              levels.reduce(0, { $0 + $1.logicalCPUCount }) == logicalCPUCount,
              clusterTypes.count == logicalCPUCount,
              Set(clusterTypes.keys) == Set(0..<logicalCPUCount)
        else { return everything }

        let coresByLetter = Dictionary(grouping: clusterTypes.keys, by: { clusterTypes[$0] ?? "" })
        guard coresByLetter.count == levels.count else { return everything }

        var remaining = coresByLetter
        var result: [CPUCoreGroup] = []
        for level in levels {
            let candidates = remaining.filter { $0.value.count == level.logicalCPUCount }
            let letter: String?
            if candidates.count == 1 {
                letter = candidates.first?.key
            } else {
                // Equal counts: fall back on the conventional letters.
                letter = candidates.keys.first { conventionalLetter($0, matches: level.name) }
            }
            guard let letter, let cores = remaining.removeValue(forKey: letter) else { return everything }
            result.append(CPUCoreGroup(name: level.name, coreIndices: cores.sorted()))
        }
        return result
    }

    private static func conventionalLetter(_ letter: String, matches levelName: String) -> Bool {
        let name = levelName.lowercased()
        switch letter.uppercased() {
        case "E": return name.hasPrefix("efficiency")
        case "P": return name.hasPrefix("performance")
        default: return false
        }
    }
}

// MARK: - Counters and rates

enum CounterMath {
    /// Growth of a monotonically increasing counter that is `bitWidth` bits
    /// wide. A 32-bit counter that went down wrapped once; a 64-bit counter that
    /// went down was reset (interface re-created, driver reloaded), and a reset
    /// has no meaningful delta.
    static func delta(previous: UInt64, current: UInt64, bitWidth: Int) -> UInt64? {
        if current >= previous { return current - previous }
        guard bitWidth < 64 else { return nil }
        let modulus = UInt64(1) << UInt64(bitWidth)
        guard previous < modulus, current < modulus else { return nil }
        return modulus - previous + current
    }

    /// Per-key deltas between two readings of a set of counters (one per
    /// network interface, one per disk). Keys seen only once are left out: they
    /// appeared or went away between the readings. A delta above `ceiling` is
    /// a counter jump rather than traffic, and is dropped.
    static func deltas<Key: Hashable>(
        previous: [Key: UInt64],
        current: [Key: UInt64],
        bitWidth: Int,
        ceiling: UInt64
    ) -> [Key: UInt64] {
        var result: [Key: UInt64] = [:]
        for (key, value) in current {
            guard let before = previous[key],
                  let delta = delta(previous: before, current: value, bitWidth: bitWidth),
                  delta <= ceiling
            else { continue }
            result[key] = delta
        }
        return result
    }

    static func summedDelta<Key: Hashable>(
        previous: [Key: UInt64],
        current: [Key: UInt64],
        bitWidth: Int,
        ceiling: UInt64
    ) -> UInt64 {
        deltas(previous: previous, current: current, bitWidth: bitWidth, ceiling: ceiling)
            .values
            .reduce(0) { $0.addingReportingOverflow($1).overflow ? UInt64.max : $0 + $1 }
    }
}

enum RateMath {
    /// Units per second, never negative, zero when no time elapsed.
    static func perSecond(_ amount: UInt64, over elapsed: TimeInterval) -> Double {
        guard elapsed > 0, elapsed.isFinite else { return 0 }
        return Double(amount) / elapsed
    }

    /// The largest delta a link or disk could plausibly produce in `elapsed`,
    /// with 50% headroom. Beyond it a reading is a counter jump, not traffic.
    static func plausibleCeiling(bytesPerSecond: Double, elapsed: TimeInterval) -> UInt64 {
        let limit = bytesPerSecond * max(elapsed, 0) * 1.5
        guard limit.isFinite, limit < Double(UInt64.max) else { return UInt64.max }
        return UInt64(limit)
    }
}

// MARK: - Axis scaling

enum AxisScale {
    /// The smallest "nice" number (1, 2, 2.5 or 5 × 10ⁿ) at or above `value`.
    static func niceCeiling(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let magnitude = pow(10, exponent)
        let fraction = value / magnitude
        let nice: Double
        if fraction <= 1.000_001 {
            nice = 1
        } else if fraction <= 2 {
            nice = 2
        } else if fraction <= 2.5 {
            nice = 2.5
        } else if fraction <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return nice * magnitude
    }

    /// An axis ceiling that stays put while the data fits comfortably, so the
    /// chart does not rescale on every sample. It grows as soon as the peak
    /// outgrows it and shrinks only once the peak falls under a quarter of it.
    static func stableCeiling(peak: Double, previous: Double?, minimum: Double) -> Double {
        let target = niceCeiling(max(peak, minimum))
        guard let previous, previous >= target else { return target }
        return peak * 4 < previous ? target : previous
    }

    /// A temperature axis from 20 °C to the next multiple of 10 at least 5 °C
    /// above the hottest reading, never below 60 °C, so an idle Mac sits low
    /// on the chart and a hot one never touches the top.
    static func temperatureRange(peak: Double) -> ClosedRange<Double> {
        let lower = 20.0
        guard peak.isFinite else { return lower...60 }
        let upper = max(60, ((peak + 5) / 10).rounded(.up) * 10)
        return lower...upper
    }
}

// MARK: - Memory

/// Page counts from `host_statistics64(HOST_VM_INFO64)`.
struct VMPageCounts: Equatable, Sendable {
    var free: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var speculative: UInt64 = 0
    var wired: UInt64 = 0
    /// Physical pages the compressor occupies (not the pages it stores).
    var compressorOccupied: UInt64 = 0
    var purgeable: UInt64 = 0
    /// File-backed pages.
    var external: UInt64 = 0
    /// Anonymous pages.
    var `internal`: UInt64 = 0
}

/// Physical memory split the way Activity Monitor splits it.
struct MemoryBreakdown: Equatable, Sendable {
    let totalBytes: UInt64
    /// Anonymous memory apps own, minus what they marked purgeable.
    let appBytes: UInt64
    /// Kernel memory that can never be paged out.
    let wiredBytes: UInt64
    /// RAM holding compressed pages.
    let compressedBytes: UInt64
    /// File cache plus purgeable memory: reclaimable on demand.
    let cachedBytes: UInt64

    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
    var freeBytes: UInt64 { totalBytes - min(totalBytes, usedBytes + cachedBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    static func make(pages: VMPageCounts, pageSize: UInt64, totalBytes: UInt64) -> MemoryBreakdown {
        let app = pages.internal - min(pages.internal, pages.purgeable)
        var remaining = totalBytes
        // Clamp in order of certainty so the parts never add up past the RAM.
        func take(_ pageCount: UInt64) -> UInt64 {
            let (bytes, overflow) = pageCount.multipliedReportingOverflow(by: pageSize)
            let granted = min(overflow ? UInt64.max : bytes, remaining)
            remaining -= granted
            return granted
        }
        let wired = take(pages.wired)
        let compressed = take(pages.compressorOccupied)
        let appBytes = take(app)
        let cached = take(pages.external + pages.purgeable)
        return MemoryBreakdown(
            totalBytes: totalBytes,
            appBytes: appBytes,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached
        )
    }
}

enum MemoryPressureLevel: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    init(kernelLevel: Int) {
        switch kernelLevel {
        case 4...: self = .critical
        case 2...: self = .warning
        default: self = .normal
        }
    }
}

// MARK: - Power

enum BatteryMath {
    /// Maximum capacity relative to design, as System Settings reports it.
    static func healthFraction(maximumCapacity: Int?, designCapacity: Int?) -> Double? {
        guard let maximumCapacity, let designCapacity, maximumCapacity > 0, designCapacity > 0 else { return nil }
        let fraction = Double(maximumCapacity) / Double(designCapacity)
        // A ratio this far off means one of the two keys changed meaning.
        guard fraction > 0.2, fraction < 1.5 else { return nil }
        return min(1, fraction)
    }

    /// Watts flowing through the battery; positive while charging.
    static func watts(millivolts: Int, milliamps: Int) -> Double {
        Double(millivolts) * Double(milliamps) / 1_000_000
    }
}

// MARK: - Temperatures

enum ThermalSensorCategory: Equatable, Sendable {
    case die
    case socFallback
    case storage
    case battery
}

struct ThermalReading: Equatable, Sendable {
    let name: String
    let celsius: Double
}

struct ThermalSummary: Equatable, Sendable {
    let averageDie: Double
    let hottestDie: Double
    let storage: Double?
    let battery: Double?
    let dieSensorCount: Int
}

enum ThermalSensorMath {
    /// Anything outside this range is an unused or uncalibrated sensor
    /// (Apple silicon reports a few at -9200 °C).
    static let plausibleCelsius: ClosedRange<Double> = 5...130

    static func category(for sensorName: String) -> ThermalSensorCategory? {
        let name = sensorName.lowercased()
        if name.contains("tdie") { return .die }
        if name.hasPrefix("soc mtr temp") { return .socFallback }
        if name.contains("nand") { return .storage }
        if name.contains("gas gauge battery") || name == "battery" { return .battery }
        return nil
    }

    /// Die temperatures when the chip reports them, otherwise the SoC sensors.
    /// Nil when nothing plausible remains, which hides the card.
    static func summarize(_ readings: [ThermalReading]) -> ThermalSummary? {
        var die: [Double] = []
        var soc: [Double] = []
        var storage: [Double] = []
        var battery: [Double] = []
        for reading in readings where plausibleCelsius.contains(reading.celsius) {
            switch category(for: reading.name) {
            case .die: die.append(reading.celsius)
            case .socFallback: soc.append(reading.celsius)
            case .storage: storage.append(reading.celsius)
            case .battery: battery.append(reading.celsius)
            case nil: continue
            }
        }
        let chip = die.isEmpty ? soc : die
        guard let hottest = chip.max() else { return nil }
        return ThermalSummary(
            averageDie: chip.reduce(0, +) / Double(chip.count),
            hottestDie: hottest,
            storage: storage.max(),
            battery: battery.isEmpty ? nil : battery.reduce(0, +) / Double(battery.count),
            dieSensorCount: chip.count
        )
    }
}

// MARK: - Grid

enum SystemCardGridMetrics {
    /// Two columns once both fit at their minimum width, otherwise one.
    static func columns(forWidth width: CGFloat, minimumCardWidth: CGFloat, spacing: CGFloat) -> Int {
        width >= minimumCardWidth * 2 + spacing ? 2 : 1
    }

    /// Rows of card indices. With an odd count the last card gets a row of
    /// its own and spans the full width, so the grid never ends on a hole.
    static func rows(cardCount: Int, columns: Int) -> [[Int]] {
        guard cardCount > 0, columns > 0 else { return [] }
        return stride(from: 0, to: cardCount, by: columns).map { start in
            Array(start..<min(start + columns, cardCount))
        }
    }
}
