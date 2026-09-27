import Foundation
import IOKit

struct GPUDescription: Equatable, Sendable {
    let name: String?
    let coreCount: Int?
}

struct GPUReading: Equatable, Sendable {
    /// Share of time the GPU was busy, 0...1.
    let deviceUtilization: Double
    let rendererUtilization: Double?
    let tilerUtilization: Double?
    /// Memory the GPU driver has in use (unified memory on Apple silicon,
    /// VRAM on a discrete card).
    let memoryInUseBytes: UInt64?
}

/// GPU activity from the `PerformanceStatistics` dictionary every
/// `IOAccelerator` publishes, the source exelban/stats and `ioreg` use. Public
/// IOKit only; a Mac whose driver publishes no utilization key has no GPU card.
final class GPUStatsReader {
    private var accelerators: [io_service_t] = []

    deinit {
        release()
    }

    /// Finds the accelerators that report utilization. Returns what the first
    /// of them is, or nil when none does.
    func prepare() -> GPUDescription? {
        release()
        let candidates = IORegistry.services(matching: "IOAccelerator")
        accelerators = candidates.filter { Self.statistics(of: $0).flatMap(Self.utilization) != nil }
        IORegistry.release(candidates.filter { !accelerators.contains($0) })
        guard let primary = accelerators.first else { return nil }
        return GPUDescription(
            name: IORegistry.string(primary, "model"),
            coreCount: IORegistry.integer(primary, "gpu-core-count")
        )
    }

    /// The busiest accelerator's reading, so a Mac with an integrated and a
    /// discrete GPU shows whichever is actually working.
    func read() -> GPUReading? {
        let readings = accelerators.compactMap { accelerator -> GPUReading? in
            guard let statistics = Self.statistics(of: accelerator),
                  let device = Self.utilization(statistics)
            else { return nil }
            return GPUReading(
                deviceUtilization: device,
                rendererUtilization: Self.percent(statistics["Renderer Utilization %"]),
                tilerUtilization: Self.percent(statistics["Tiler Utilization %"]),
                memoryInUseBytes: Self.bytes(statistics["In use system memory"])
                    ?? Self.bytes(statistics["vramUsedBytes"])
            )
        }
        return readings.max { $0.deviceUtilization < $1.deviceUtilization }
    }

    func release() {
        IORegistry.release(accelerators)
        accelerators = []
    }

    private static func statistics(of accelerator: io_service_t) -> [String: Any]? {
        IORegistry.dictionary(accelerator, "PerformanceStatistics")
    }

    private static func utilization(_ statistics: [String: Any]) -> Double? {
        percent(statistics["Device Utilization %"]) ?? percent(statistics["GPU Activity(%)"])
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return min(100, max(0, number.doubleValue)) / 100
    }

    private static func bytes(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.int64Value > 0 else { return nil }
        return number.registryCounter
    }
}
