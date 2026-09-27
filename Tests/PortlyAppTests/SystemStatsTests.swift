import AppKit
import SwiftUI
@testable import PortlyApp
import XCTest

final class SystemStatsMathTests: XCTestCase {
    // MARK: - Ring buffer

    func testRingBufferKeepsInsertionOrderBeforeItFills() {
        var buffer = RingBuffer<Int>(capacity: 4)
        buffer.append(1)
        buffer.append(2)
        XCTAssertEqual(buffer.elements, [1, 2])
        XCTAssertEqual(buffer.last, 2)
        XCTAssertEqual(buffer.count, 2)
    }

    func testRingBufferOverwritesTheOldestOnceFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...7 {
            buffer.append(value)
        }
        XCTAssertEqual(buffer.elements, [5, 6, 7])
        XCTAssertEqual(buffer.last, 7)
        XCTAssertEqual(buffer.count, 3)
    }

    func testRingBufferRemoveAllStartsOver() {
        var buffer = RingBuffer<Int>(capacity: 2)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.last)
        buffer.append(9)
        XCTAssertEqual(buffer.elements, [9])
    }

    func testRingBufferEqualityComparesContentsInOrder() {
        var lhs = RingBuffer<Int>(capacity: 2)
        var rhs = RingBuffer<Int>(capacity: 2)
        [1, 2, 3].forEach { lhs.append($0) }
        [2, 3].forEach { rhs.append($0) }
        XCTAssertEqual(lhs, rhs)
    }

    // MARK: - CPU ticks

    func testCPUUsageSplitsUserSystemAndIdle() throws {
        let before = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let after = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        let usage = try XCTUnwrap(CPULoadMath.usage(from: before, to: after))
        // 60 user + 20 nice = 80 user, 20 system, 100 idle over 200 ticks.
        XCTAssertEqual(usage.user, 0.4, accuracy: 1e-9)
        XCTAssertEqual(usage.system, 0.1, accuracy: 1e-9)
        XCTAssertEqual(usage.idle, 0.5, accuracy: 1e-9)
        XCTAssertEqual(usage.total, 0.5, accuracy: 1e-9)
    }

    func testCPUUsageSurvivesA32BitTickWraparound() throws {
        let before = CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29, nice: 0)
        let after = CPUTicks(user: 10, system: 0, idle: 10, nice: 0)
        let usage = try XCTUnwrap(CPULoadMath.usage(from: before, to: after))
        // 20 user ticks and 40 idle ticks across the wrap.
        XCTAssertEqual(usage.user, 20.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(usage.idle, 40.0 / 60.0, accuracy: 1e-9)
    }

    func testCPUUsageIsNilWhenNoTimeElapsed() {
        let ticks = CPUTicks(user: 5, system: 5, idle: 5, nice: 5)
        XCTAssertNil(CPULoadMath.usage(from: ticks, to: ticks))
    }

    func testCombinedUsageWeighsEveryCoreByItsTicks() throws {
        let before = [
            CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
        ]
        let after = [
            CPUTicks(user: 100, system: 0, idle: 0, nice: 0), // fully busy
            CPUTicks(user: 0, system: 0, idle: 100, nice: 0), // fully idle
        ]
        let usage = try XCTUnwrap(CPULoadMath.combined(previous: before, current: after))
        XCTAssertEqual(usage.total, 0.5, accuracy: 1e-9)
        XCTAssertEqual(CPULoadMath.perCore(previous: before, current: after), [1, 0])
    }

    func testCoreCountChangeYieldsNoReading() {
        let one = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let two = one + one
        XCTAssertNil(CPULoadMath.combined(previous: one, current: two))
        XCTAssertEqual(CPULoadMath.perCore(previous: one, current: two), [])
    }

    // MARK: - Core topology

    private let appleSiliconLevels = [
        CPUTopologyMath.PerformanceLevel(name: "Performance", logicalCPUCount: 4),
        CPUTopologyMath.PerformanceLevel(name: "Efficiency", logicalCPUCount: 2),
    ]

    func testTopologyMapsClusterLettersToPerformanceLevels() {
        let groups = CPUTopologyMath.groups(
            levels: appleSiliconLevels,
            clusterTypes: [0: "E", 1: "E", 2: "P", 3: "P", 4: "P", 5: "P"],
            logicalCPUCount: 6
        )
        XCTAssertEqual(groups, [
            CPUCoreGroup(name: "Performance", coreIndices: [2, 3, 4, 5]),
            CPUCoreGroup(name: "Efficiency", coreIndices: [0, 1]),
        ])
    }

    func testTopologyUsesConventionalLettersWhenCountsTie() {
        let levels = [
            CPUTopologyMath.PerformanceLevel(name: "Performance", logicalCPUCount: 2),
            CPUTopologyMath.PerformanceLevel(name: "Efficiency", logicalCPUCount: 2),
        ]
        let groups = CPUTopologyMath.groups(
            levels: levels,
            clusterTypes: [0: "E", 1: "E", 2: "P", 3: "P"],
            logicalCPUCount: 4
        )
        XCTAssertEqual(groups.map(\.coreIndices), [[2, 3], [0, 1]])
    }

    func testTopologyFallsBackToOneGroupWithoutACleanMatch() {
        let everything = [CPUCoreGroup(name: "Cores", coreIndices: [0, 1, 2, 3, 4, 5])]
        // No device tree information (Intel, or a layout change).
        XCTAssertEqual(
            CPUTopologyMath.groups(levels: appleSiliconLevels, clusterTypes: [:], logicalCPUCount: 6),
            everything
        )
        // Counts that do not add up.
        XCTAssertEqual(
            CPUTopologyMath.groups(
                levels: appleSiliconLevels,
                clusterTypes: [0: "E", 1: "P", 2: "P", 3: "P", 4: "P", 5: "P"],
                logicalCPUCount: 6
            ),
            everything
        )
        // A single performance level.
        XCTAssertEqual(
            CPUTopologyMath.groups(
                levels: [CPUTopologyMath.PerformanceLevel(name: "Performance", logicalCPUCount: 6)],
                clusterTypes: [:],
                logicalCPUCount: 6
            ),
            everything
        )
    }

    func testTopologyRejectsAmbiguousUnknownLetters() {
        let levels = [
            CPUTopologyMath.PerformanceLevel(name: "Super", logicalCPUCount: 2),
            CPUTopologyMath.PerformanceLevel(name: "Performance", logicalCPUCount: 2),
        ]
        let groups = CPUTopologyMath.groups(
            levels: levels,
            clusterTypes: [0: "M", 1: "M", 2: "X", 3: "X"],
            logicalCPUCount: 4
        )
        XCTAssertEqual(groups.count, 1, "a guess would be worse than one honest group")
    }

    // MARK: - Counters

    func testCounterDeltaHandlesA32BitWraparound() {
        XCTAssertEqual(CounterMath.delta(previous: 0xFFFF_FF00, current: 0x100, bitWidth: 32), 0x200)
        XCTAssertEqual(CounterMath.delta(previous: 10, current: 25, bitWidth: 32), 15)
    }

    func testA64BitCounterThatWentDownWasReset() {
        XCTAssertNil(CounterMath.delta(previous: 5_000, current: 10, bitWidth: 64))
        XCTAssertEqual(CounterMath.delta(previous: 10, current: 5_000, bitWidth: 64), 4_990)
    }

    func testOutOfRangeValuesAreNotTreatedAsA32BitWrap() {
        XCTAssertNil(CounterMath.delta(previous: UInt64(UInt32.max) + 5, current: 3, bitWidth: 32))
    }

    func testSummedDeltaIgnoresInterfacesThatCameOrWent() {
        let previous: [String: UInt64] = ["en0": 1_000, "en5": 400]
        let current: [String: UInt64] = ["en0": 1_600, "en7": 90_000]
        XCTAssertEqual(
            CounterMath.summedDelta(previous: previous, current: current, bitWidth: 64, ceiling: .max),
            600
        )
    }

    func testSummedDeltaDropsJumpsAboveTheCeiling() {
        let previous: [String: UInt64] = ["en0": 0, "en1": 0]
        let current: [String: UInt64] = ["en0": 500, "en1": 9_000_000]
        XCTAssertEqual(
            CounterMath.summedDelta(previous: previous, current: current, bitWidth: 64, ceiling: 1_000),
            500
        )
        XCTAssertEqual(
            CounterMath.deltas(previous: previous, current: current, bitWidth: 64, ceiling: 1_000),
            ["en0": 500]
        )
    }

    func testSummedDeltaCountsA32BitInterfaceThatWrapped() {
        let previous: [String: UInt64] = ["en0": UInt64(UInt32.max) - 99]
        let current: [String: UInt64] = ["en0": 900]
        XCTAssertEqual(
            CounterMath.summedDelta(previous: previous, current: current, bitWidth: 32, ceiling: .max),
            1_000
        )
    }

    // MARK: - Rates

    func testRateMath() {
        XCTAssertEqual(RateMath.perSecond(3_000, over: 2), 1_500)
        XCTAssertEqual(RateMath.perSecond(3_000, over: 0), 0)
        XCTAssertEqual(RateMath.perSecond(3_000, over: -1), 0)
        XCTAssertEqual(RateMath.perSecond(3_000, over: .infinity), 0)
    }

    func testPlausibleCeilingAddsHeadroom() {
        XCTAssertEqual(RateMath.plausibleCeiling(bytesPerSecond: 1_000, elapsed: 2), 3_000)
        XCTAssertEqual(RateMath.plausibleCeiling(bytesPerSecond: .infinity, elapsed: 1), .max)
    }

    func testSampleGapDetection() {
        XCTAssertFalse(SampleTiming.isGap(elapsed: 1.02, interval: 1))
        XCTAssertFalse(SampleTiming.isGap(elapsed: 2.5, interval: 1))
        XCTAssertTrue(SampleTiming.isGap(elapsed: 3.5, interval: 1))
        XCTAssertTrue(SampleTiming.isGap(elapsed: 0, interval: 1))
    }

    // MARK: - Axis

    func testNiceCeiling() {
        XCTAssertEqual(AxisScale.niceCeiling(1), 1)
        XCTAssertEqual(AxisScale.niceCeiling(1.2), 2)
        XCTAssertEqual(AxisScale.niceCeiling(2.4), 2.5)
        XCTAssertEqual(AxisScale.niceCeiling(3.4e6), 5e6)
        XCTAssertEqual(AxisScale.niceCeiling(7_000), 10_000)
        XCTAssertEqual(AxisScale.niceCeiling(0.07), 0.1, accuracy: 1e-12)
        XCTAssertEqual(AxisScale.niceCeiling(0), 1)
    }

    func testStableCeilingHoldsUntilThePeakOutgrowsOrShrinksAway() {
        let first = AxisScale.stableCeiling(peak: 3.4e6, previous: nil, minimum: 1e5)
        XCTAssertEqual(first, 5e6)
        // Smaller peaks keep the axis still...
        XCTAssertEqual(AxisScale.stableCeiling(peak: 2e6, previous: first, minimum: 1e5), 5e6)
        // ...a bigger one grows it at once...
        XCTAssertEqual(AxisScale.stableCeiling(peak: 6e6, previous: first, minimum: 1e5), 1e7)
        // ...and it only shrinks once the peak is under a quarter of it.
        XCTAssertEqual(AxisScale.stableCeiling(peak: 1e6, previous: first, minimum: 1e5), 1e6)
        XCTAssertEqual(AxisScale.stableCeiling(peak: 0, previous: nil, minimum: 1e5), 1e5)
    }

    func testTemperatureRange() {
        XCTAssertEqual(AxisScale.temperatureRange(peak: 38), 20...60)
        XCTAssertEqual(AxisScale.temperatureRange(peak: 71), 20...80)
        XCTAssertEqual(AxisScale.temperatureRange(peak: 95), 20...100)
    }

    // MARK: - History window

    func testHistoryWindowKeepsOneEarlierSampleOfTheSameSegment() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<5).map { index in
            TimedSample(id: index, date: start.addingTimeInterval(Double(index)), segment: 1, value: index)
        }
        let visible = HistoryWindow.visible(samples, since: start.addingTimeInterval(2.5))
        XCTAssertEqual(visible.map(\.id), [2, 3, 4])
    }

    func testHistoryWindowNeverReachesAcrossAPause() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [
            TimedSample(id: 0, date: start, segment: 1, value: 0),
            TimedSample(id: 1, date: start.addingTimeInterval(60), segment: 2, value: 1),
            TimedSample(id: 2, date: start.addingTimeInterval(61), segment: 2, value: 2),
        ]
        XCTAssertEqual(HistoryWindow.visible(samples, since: start.addingTimeInterval(30)).map(\.id), [1, 2])
        XCTAssertEqual(HistoryWindow.visible(samples, since: start.addingTimeInterval(90)).map(\.id), [])
    }

    // MARK: - Memory

    func testMemoryBreakdownMatchesActivityMonitor() {
        let page: UInt64 = 16_384
        let pages = VMPageCounts(
            free: 1_000,
            active: 50_000,
            inactive: 40_000,
            speculative: 500,
            wired: 20_000,
            compressorOccupied: 10_000,
            purgeable: 2_000,
            external: 30_000,
            internal: 60_000
        )
        let total = 200_000 * page
        let memory = MemoryBreakdown.make(pages: pages, pageSize: page, totalBytes: total)
        XCTAssertEqual(memory.appBytes, 58_000 * page) // anonymous minus purgeable
        XCTAssertEqual(memory.wiredBytes, 20_000 * page)
        XCTAssertEqual(memory.compressedBytes, 10_000 * page)
        XCTAssertEqual(memory.cachedBytes, 32_000 * page) // file-backed plus purgeable
        XCTAssertEqual(memory.usedBytes, 88_000 * page)
        XCTAssertEqual(memory.freeBytes, 80_000 * page)
        XCTAssertEqual(memory.usedFraction, 0.44, accuracy: 1e-9)
    }

    func testMemoryBreakdownNeverAddsUpPastPhysicalMemory() {
        let pages = VMPageCounts(wired: 900, compressorOccupied: 900, purgeable: 0, external: 900, internal: 900)
        let memory = MemoryBreakdown.make(pages: pages, pageSize: 1, totalBytes: 1_000)
        XCTAssertEqual(memory.wiredBytes, 900)
        XCTAssertEqual(memory.compressedBytes, 100)
        XCTAssertEqual(memory.appBytes, 0)
        XCTAssertEqual(memory.cachedBytes, 0)
        XCTAssertEqual(memory.freeBytes, 0)
    }

    func testPurgeableLargerThanAnonymousDoesNotUnderflow() {
        let pages = VMPageCounts(purgeable: 50, internal: 10)
        let memory = MemoryBreakdown.make(pages: pages, pageSize: 1, totalBytes: 1_000)
        XCTAssertEqual(memory.appBytes, 0)
        XCTAssertEqual(memory.cachedBytes, 50)
    }

    func testMemoryPressureLevels() {
        XCTAssertEqual(MemoryPressureLevel(kernelLevel: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(kernelLevel: 0), .normal)
        XCTAssertEqual(MemoryPressureLevel(kernelLevel: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(kernelLevel: 4), .critical)
    }

    // MARK: - Battery and temperatures

    func testBatteryHealth() throws {
        XCTAssertEqual(try XCTUnwrap(BatteryMath.healthFraction(maximumCapacity: 8_150, designCapacity: 8_579)), 0.95, accuracy: 0.001)
        XCTAssertEqual(BatteryMath.healthFraction(maximumCapacity: 9_000, designCapacity: 8_579), 1)
        XCTAssertNil(BatteryMath.healthFraction(maximumCapacity: 100, designCapacity: 8_579), "a percentage is not a capacity")
        XCTAssertNil(BatteryMath.healthFraction(maximumCapacity: nil, designCapacity: 8_579))
        XCTAssertNil(BatteryMath.healthFraction(maximumCapacity: 8_000, designCapacity: 0))
    }

    func testBatteryWatts() {
        XCTAssertEqual(BatteryMath.watts(millivolts: 12_554, milliamps: -983), -12.340582, accuracy: 1e-6)
    }

    func testThermalSummaryUsesDieSensorsAndDropsImplausibleReadings() throws {
        let summary = try XCTUnwrap(ThermalSensorMath.summarize([
            ThermalReading(name: "PMU tdie1", celsius: 40),
            ThermalReading(name: "PMU tdie2", celsius: 50),
            ThermalReading(name: "PMU tdev1", celsius: -9_201),
            ThermalReading(name: "PMU tdie3", celsius: -9_201),
            ThermalReading(name: "NAND CH0 temp", celsius: 31),
            ThermalReading(name: "gas gauge battery", celsius: 27),
            ThermalReading(name: "gas gauge battery", celsius: 29),
            ThermalReading(name: "als-temp", celsius: 60),
        ]))
        XCTAssertEqual(summary.averageDie, 45)
        XCTAssertEqual(summary.hottestDie, 50)
        XCTAssertEqual(summary.storage, 31)
        XCTAssertEqual(summary.battery, 28)
        XCTAssertEqual(summary.dieSensorCount, 2)
    }

    func testThermalSummaryFallsBackToSoCSensors() throws {
        let summary = try XCTUnwrap(ThermalSensorMath.summarize([
            ThermalReading(name: "SOC MTR Temp Sensor0", celsius: 42),
            ThermalReading(name: "SOC MTR Temp Sensor1", celsius: 44),
        ]))
        XCTAssertEqual(summary.averageDie, 43)
        XCTAssertNil(summary.storage)
    }

    func testThermalSummaryIsNilWithoutAPlausibleChipSensor() {
        XCTAssertNil(ThermalSensorMath.summarize([]))
        XCTAssertNil(ThermalSensorMath.summarize([ThermalReading(name: "PMU tdie1", celsius: -9_200)]))
        XCTAssertNil(ThermalSensorMath.summarize([ThermalReading(name: "NAND CH0 temp", celsius: 31)]))
    }

    // MARK: - Grid

    func testGridCollapsesToOneColumnWhenNarrow() {
        XCTAssertEqual(SystemCardGridMetrics.columns(forWidth: 700, minimumCardWidth: 340, spacing: 12), 2)
        XCTAssertEqual(SystemCardGridMetrics.columns(forWidth: 691, minimumCardWidth: 340, spacing: 12), 1)
    }

    func testGridGivesALoneLastCardItsOwnRow() {
        XCTAssertEqual(SystemCardGridMetrics.rows(cardCount: 7, columns: 2), [[0, 1], [2, 3], [4, 5], [6]])
        XCTAssertEqual(SystemCardGridMetrics.rows(cardCount: 3, columns: 1), [[0], [1], [2]])
        XCTAssertEqual(SystemCardGridMetrics.rows(cardCount: 0, columns: 2), [])
    }

    // MARK: - Chart bands

    private func points(_ values: [Double], start: Int = 0) -> [LiveChartPoint] {
        values.enumerated().map { index, value in
            LiveChartPoint(id: start + index, date: Date(timeIntervalSince1970: Double(index)), segment: 0, value: value)
        }
    }

    func testStackedBandsSumSeriesSampleBySample() {
        let bands = LiveChartBands.make([points([10, 20]), points([5, 1])], style: .stacked)
        XCTAssertEqual(bands[1].map(\.lower), [10, 20])
        XCTAssertEqual(bands[1].map(\.upper), [15, 21])
        XCTAssertEqual(bands[1].map(\.value), [5, 1], "the tooltip shows each part, not the running total")
    }

    func testMirroredBandsGrowTheSecondSeriesDownward() {
        let bands = LiveChartBands.make([points([4]), points([3])], style: .mirrored)
        XCTAssertEqual(bands[0].first?.upper, 4)
        XCTAssertEqual(bands[1].first?.lower, -3)
        XCTAssertEqual(bands[1].first?.edge, -3)
        XCTAssertEqual(bands[1].first?.upper, 0)
    }

    // MARK: - Formatting

    func testDurationsAndAges() {
        let space = "\u{00A0}"
        XCTAssertEqual(SystemStatsFormat.duration(45), "45\(space)s")
        XCTAssertEqual(SystemStatsFormat.duration(12 * 60), "12\(space)m")
        XCTAssertEqual(SystemStatsFormat.duration(5 * 3_600 + 12 * 60), "5\(space)h 12\(space)m")
        XCTAssertEqual(SystemStatsFormat.duration(3 * 86_400 + 4 * 3_600), "3\(space)d 4\(space)h")
        XCTAssertEqual(SystemStatsFormat.age(0.2), "now")
        XCTAssertEqual(SystemStatsFormat.age(12), "12\(space)s ago")
        XCTAssertEqual(SystemStatsFormat.age(80), "1\(space)m 20\(space)s ago")
        XCTAssertEqual(SystemStatsFormat.age(120), "2\(space)m ago")
    }

    func testPercentAndTemperatureConversion() {
        XCTAssertEqual(SystemStatsFormat.percent(0.42), "42%")
        XCTAssertEqual(SystemStatsFormat.percent(0), "0%")
        XCTAssertEqual(SystemStatsFormat.percent(1), "100%")
        XCTAssertEqual(SystemStatsFormat.displayTemperature(100, fahrenheit: true), 212)
        XCTAssertEqual(SystemStatsFormat.displayTemperature(37, fahrenheit: false), 37)
        // Units follow the system language; the shape does not.
        XCTAssertTrue(SystemStatsFormat.rate(0).hasPrefix("0\u{00A0}"))
        XCTAssertTrue(SystemStatsFormat.rate(0).hasSuffix("/s"))
        XCTAssertEqual(SystemStatsFormat.axisRate(0), "0")
        XCTAssertEqual(SystemStatsFormat.axisMemory(gibibytes: 0), "0")
        XCTAssertFalse(SystemStatsFormat.rate(2_500_000).contains(" "), "value and unit never wrap apart")
    }
}

/// The readers against the real machine: whatever this Mac is, they must not
/// crash and must stay within physical bounds.
final class SystemStatsReaderSmokeTests: XCTestCase {
    func testSamplerProducesSaneFramesOnThisMac() throws {
        let sampler = SystemStatsSampler()
        let start = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let first = sampler.start(now: start, uptime: uptime)
        XCTAssertTrue(first.cards.contains(.cpu))
        XCTAssertTrue(first.cards.contains(.memory))
        XCTAssertTrue(first.cards.contains(.power))
        XCTAssertNotNil(first.summary)

        let memory = try XCTUnwrap(first.memory)
        XCTAssertEqual(memory.current.breakdown.totalBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(
            memory.current.breakdown.usedBytes + memory.current.breakdown.cachedBytes,
            memory.current.breakdown.totalBytes
        )
        XCTAssertGreaterThan(memory.current.breakdown.usedBytes, 0)

        Thread.sleep(forTimeInterval: 1)
        let second = sampler.sample(now: start.addingTimeInterval(1), uptime: uptime + 1)
        let cpu = try XCTUnwrap(second.cpu?.current)
        XCTAssertTrue((0...1).contains(cpu.usage.total))
        XCTAssertEqual(cpu.perCore.count, second.cpu?.description.logicalCPUCount)
        XCTAssertEqual(second.cpu?.history.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(second.network?.current).primary, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(second.disk?.current).primary, 0)
        if let gpu = second.gpu?.current {
            XCTAssertTrue((0...1).contains(gpu.deviceUtilization))
        }
        if let thermals = first.thermals?.current {
            XCTAssertTrue(ThermalSensorMath.plausibleCelsius.contains(thermals.hottestDie))
        }
        sampler.stop()
    }

    func testCoreGroupsCoverEveryLogicalCPUExactlyOnce() {
        let description = CPUStatsReader.describe()
        let indices = description.groups.flatMap(\.coreIndices).sorted()
        XCTAssertEqual(indices, Array(0..<description.logicalCPUCount))
    }
}

/// Layout smoke test: every card renders from fixture data without tripping
/// the custom layouts or the charts.
final class SystemStatsViewTests: XCTestCase {
    func testCardsLayOutInOneAndTwoColumns() {
        let feeds = SystemStatsFixtures.feeds()
        for width in [420.0, 900.0] {
            let host = NSHostingView(rootView: SystemStatsFixtureGrid(feeds: feeds).frame(width: width))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1_600)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 400)
        }
    }
}

struct SystemStatsFixtureGrid: View {
    let feeds: SystemStatsFixtures.Feeds

    var body: some View {
        SystemCardGridLayout {
            CPUStatCard(feed: feeds.cpu)
            MemoryStatCard(feed: feeds.memory)
            GPUStatCard(feed: feeds.gpu)
            NetworkStatCard(feed: feeds.network)
            DiskStatCard(feed: feeds.disk)
            ThermalStatCard(feed: feeds.thermals)
            PowerStatCard(feed: feeds.power, showsThermalState: false)
        }
        .padding(24)
    }
}

enum SystemStatsFixtures {
    struct Feeds {
        let cpu = SystemStatsFeed<CPUCardState>()
        let memory = SystemStatsFeed<MemoryCardState>()
        let gpu = SystemStatsFeed<GPUCardState>()
        let network = SystemStatsFeed<NetworkCardState>()
        let disk = SystemStatsFeed<DiskCardState>()
        let thermals = SystemStatsFeed<ThermalCardState>()
        let power = SystemStatsFeed<PowerCardState>()
    }

    static func feeds() -> Feeds {
        let feeds = Feeds()
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        func history<Value>(_ make: (Double) -> Value) -> [TimedSample<Value>] {
            (0..<120).map { index in
                let phase = Double(index) / 8
                return TimedSample(
                    id: index,
                    date: end.addingTimeInterval(Double(index - 119)),
                    segment: index < 50 ? 1 : 2,
                    value: make(phase)
                )
            }
        }
        let gib: UInt64 = 1_073_741_824
        let groups = [
            CPUCoreGroup(name: "Performance", coreIndices: Array(4..<14)),
            CPUCoreGroup(name: "Efficiency", coreIndices: Array(0..<4)),
        ]
        feeds.cpu.publish(CPUCardState(
            description: CPUDescription(chipName: "Apple M4 Pro", logicalCPUCount: 14, groups: groups),
            current: CPUReading(
                usage: CPUUsage(user: 0.24, system: 0.09, idle: 0.67),
                perCore: (0..<14).map { 0.1 + Double($0 % 5) * 0.18 }
            ),
            loadAverage: [3.21, 2.87, 2.55],
            uptime: 3 * 86_400 + 4 * 3_600,
            history: history { CPUUsage(user: 0.2 + 0.1 * sin($0), system: 0.08 + 0.03 * cos($0), idle: 0.6) },
            windowEnd: end
        ))
        let breakdown = MemoryBreakdown(
            totalBytes: 24 * gib,
            appBytes: 10 * gib,
            wiredBytes: 3 * gib,
            compressedBytes: 4 * gib,
            cachedBytes: 5 * gib
        )
        feeds.memory.publish(MemoryCardState(
            current: MemoryReading(breakdown: breakdown, pressure: .warning, swap: SwapUsage(usedBytes: gib, totalBytes: 2 * gib)),
            history: history { _ in breakdown },
            windowEnd: end
        ))
        feeds.gpu.publish(GPUCardState(
            description: GPUDescription(name: "Apple M4 Pro", coreCount: 20),
            current: GPUReading(deviceUtilization: 0.37, rendererUtilization: 0.36, tilerUtilization: 0.31, memoryInUseBytes: 777_306_112),
            history: history { 0.3 + 0.2 * sin($0) },
            windowEnd: end
        ))
        feeds.network.publish(NetworkCardState(
            current: PairedRate(primary: 1_250_000, secondary: 84_000),
            peak: PairedRate(primary: 3_400_000, secondary: 250_000),
            totalReceived: 180_000_000,
            totalSent: 12_000_000,
            interfaces: ["Wi-Fi"],
            history: history { PairedRate(primary: 1_500_000 * (1 + sin($0)), secondary: 100_000 * (1 + cos($0))) },
            axisCeiling: 5_000_000,
            windowEnd: end
        ))
        feeds.disk.publish(DiskCardState(
            current: PairedRate(primary: 12_000_000, secondary: 3_000_000),
            operations: PairedRate(primary: 420, secondary: 96),
            totalRead: 2_400_000_000,
            totalWritten: 800_000_000,
            volume: VolumeCapacity(name: "Macintosh HD", totalBytes: 994_000_000_000, availableBytes: 312_000_000_000),
            history: history { PairedRate(primary: 10_000_000 * (1 + sin($0)), secondary: 4_000_000 * (1 + cos($0))) },
            axisCeiling: 50_000_000,
            windowEnd: end
        ))
        let thermal = ThermalSummary(averageDie: 41, hottestDie: 47, storage: 31, battery: 28, dieSensorCount: 42)
        feeds.thermals.publish(ThermalCardState(
            current: thermal,
            thermalState: .fair,
            history: history { ThermalSummary(averageDie: 40 + 3 * sin($0), hottestDie: 46 + 4 * sin($0), storage: 31, battery: 28, dieSensorCount: 42) },
            axisRange: 20...60,
            windowEnd: end
        ))
        feeds.power.publish(PowerCardState(
            current: PowerReading(
                battery: BatteryReading(
                    level: 0.82,
                    isCharging: false,
                    isCharged: false,
                    minutesToEmpty: 421,
                    minutesToFull: nil,
                    cycleCount: 201,
                    health: 0.95
                ),
                onExternalPower: false,
                adapterWatts: nil,
                systemWatts: 12.3,
                thermalState: .nominal,
                lowPowerMode: false
            ),
            history: history { 12 + 4 * sin($0) },
            axisCeiling: 20,
            windowEnd: end
        ))
        return feeds
    }
}
