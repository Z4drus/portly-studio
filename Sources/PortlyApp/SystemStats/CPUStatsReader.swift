import Darwin
import Foundation
import IOKit

/// What the chip is, read once per session.
struct CPUDescription: Equatable, Sendable {
    let chipName: String?
    let logicalCPUCount: Int
    let groups: [CPUCoreGroup]
}

/// One CPU reading: whole-machine split plus every core's busy fraction.
struct CPUReading: Equatable, Sendable {
    let usage: CPUUsage
    let perCore: [Double]
}

/// Per-core scheduler ticks from `host_processor_info`, turned into usage by
/// diffing consecutive readings (the same technique as Activity Monitor and
/// exelban/stats).
final class CPUStatsReader {
    private let host = mach_host_self()
    private var previousTicks: [CPUTicks]?

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// Forgets the baseline, so the next `read()` only primes it.
    func resetBaseline() {
        previousTicks = nil
    }

    /// Nil on the first call after a reset (there is nothing to diff yet) or
    /// when the kernel refuses the query.
    func read() -> CPUReading? {
        guard let ticks = currentTicks() else { return nil }
        let baseline = previousTicks
        previousTicks = ticks
        guard let baseline,
              let usage = CPULoadMath.combined(previous: baseline, current: ticks)
        else { return nil }
        return CPUReading(
            usage: usage,
            perCore: CPULoadMath.perCore(previous: baseline, current: ticks)
        )
    }

    /// 1, 5 and 15 minute load averages.
    static func loadAverage() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return loads
    }

    static func uptime(now: Date) -> TimeInterval? {
        guard let boot = Sysctl.value("kern.boottime", as: timeval.self, initial: timeval()),
              boot.tv_sec > 0
        else { return nil }
        let booted = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        let uptime = now.timeIntervalSince(booted)
        return uptime > 0 ? uptime : nil
    }

    static func describe() -> CPUDescription {
        let logical = Sysctl.integer("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let levelCount = Sysctl.integer("hw.nperflevels") ?? 1
        let levels: [CPUTopologyMath.PerformanceLevel] = (0..<max(0, levelCount)).compactMap { index in
            guard let count = Sysctl.integer("hw.perflevel\(index).logicalcpu"), count > 0 else { return nil }
            let name = Sysctl.string("hw.perflevel\(index).name") ?? "Level \(index)"
            return CPUTopologyMath.PerformanceLevel(name: name, logicalCPUCount: count)
        }
        return CPUDescription(
            chipName: Sysctl.string("machdep.cpu.brand_string"),
            logicalCPUCount: logical,
            groups: CPUTopologyMath.groups(
                levels: levels,
                clusterTypes: levels.count > 1 ? clusterTypesByLogicalCPU() : [:],
                logicalCPUCount: logical
            )
        )
    }

    // MARK: - Private

    private func currentTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        let stride = Int(CPU_STATE_MAX)
        guard cpuCount > 0, Int(infoCount) >= Int(cpuCount) * stride else { return nil }
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// `cluster-type` ("E", "P", …) of every core in the device tree, keyed by
    /// its logical CPU id. Empty on Intel Macs or if the layout ever changes.
    private static func clusterTypesByLogicalCPU() -> [Int: String] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var types: [Int: String] = [:]
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard let logicalID = IORegistry.integer(child, "logical-cpu-id"),
                  let clusterType = IORegistry.string(child, "cluster-type")
            else { continue }
            types[logicalID] = clusterType
        }
        return types
    }
}
