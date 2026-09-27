import Foundation
import IOKit

/// Cumulative I/O counters of every physical block device, keyed by the
/// driver's registry id (stable while the disk stays attached).
struct DiskCounters: Equatable, Sendable {
    var bytesRead: [UInt64: UInt64] = [:]
    var bytesWritten: [UInt64: UInt64] = [:]
    var readOperations: [UInt64: UInt64] = [:]
    var writeOperations: [UInt64: UInt64] = [:]
}

struct VolumeCapacity: Equatable, Sendable {
    let name: String
    let totalBytes: UInt64
    /// What macOS would free up for an important task, purgeable space included.
    let availableBytes: UInt64

    var usedBytes: UInt64 { totalBytes - min(totalBytes, availableBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

/// Disk throughput from the `Statistics` dictionary of each
/// `IOBlockStorageDriver`, the counters `iostat` and exelban/stats read.
/// Mounted disk images are skipped: their reads already show up once on the
/// disk that holds the image file.
final class DiskStatsReader {
    /// Registry id → whether the driver sits on a real disk. Classified once.
    private var isPhysicalByID: [UInt64: Bool] = [:]

    func read() -> DiskCounters? {
        let drivers = IORegistry.services(matching: "IOBlockStorageDriver")
        defer { IORegistry.release(drivers) }
        guard !drivers.isEmpty else { return nil }

        var counters = DiskCounters()
        var seen = Set<UInt64>()
        defer { isPhysicalByID = isPhysicalByID.filter { seen.contains($0.key) } }
        for driver in drivers {
            guard let id = IORegistry.registryID(driver) else { continue }
            seen.insert(id)
            guard isPhysical(driver, id: id),
                  let statistics = IORegistry.dictionary(driver, "Statistics")
            else { continue }
            counters.bytesRead[id] = (statistics["Bytes (Read)"] as? NSNumber)?.registryCounter
            counters.bytesWritten[id] = (statistics["Bytes (Write)"] as? NSNumber)?.registryCounter
            counters.readOperations[id] = (statistics["Operations (Read)"] as? NSNumber)?.registryCounter
            counters.writeOperations[id] = (statistics["Operations (Write)"] as? NSNumber)?.registryCounter
        }
        return counters
    }

    /// The startup volume. `volumeAvailableCapacityForImportantUsage` can take
    /// a while to compute, so the sampler asks rarely.
    static func bootVolume() -> VolumeCapacity? {
        // A fresh URL each time: URLs cache resource values.
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? root.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
            ?? 0
        return VolumeCapacity(
            name: values.volumeLocalizedName ?? "Startup disk",
            totalBytes: UInt64(total),
            availableBytes: UInt64(max(0, available))
        )
    }

    private func isPhysical(_ driver: io_service_t, id: UInt64) -> Bool {
        if let known = isPhysicalByID[id] { return known }
        let physical = !Self.sitsOnDiskImage(driver)
        isPhysicalByID[id] = physical
        return physical
    }

    /// Walks a few providers up looking for a disk image device.
    private static func sitsOnDiskImage(_ driver: io_service_t) -> Bool {
        var current = driver
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<4 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
                return false
            }
            IOObjectRelease(current)
            current = parent
            let className = IORegistry.className(parent) ?? ""
            if className.contains("DiskImage") || className.contains("HDIX") {
                return true
            }
        }
        return false
    }
}
