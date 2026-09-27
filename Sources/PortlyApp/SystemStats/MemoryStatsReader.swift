import Darwin
import Foundation

struct SwapUsage: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64
}

struct MemoryReading: Equatable, Sendable {
    let breakdown: MemoryBreakdown
    let pressure: MemoryPressureLevel
    let swap: SwapUsage?
}

/// Whole-machine memory from the VM statistics, split the way Activity Monitor
/// and exelban/stats split it (app, wired, compressed, cached, free).
final class MemoryStatsReader {
    private let host: mach_port_t
    private let pageSize: UInt64
    private let totalBytes = ProcessInfo.processInfo.physicalMemory

    init() {
        let port = mach_host_self()
        host = port
        var size: vm_size_t = 0
        if host_page_size(port, &size) == KERN_SUCCESS, size > 0 {
            pageSize = UInt64(size)
        } else {
            pageSize = UInt64(getpagesize())
        }
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func read() -> MemoryReading? {
        guard let pages = pageCounts() else { return nil }
        return MemoryReading(
            breakdown: MemoryBreakdown.make(pages: pages, pageSize: pageSize, totalBytes: totalBytes),
            pressure: MemoryPressureLevel(kernelLevel: Sysctl.integer("kern.memorystatus_vm_pressure_level") ?? 1),
            swap: Self.swapUsage()
        )
    }

    private func pageCounts() -> VMPageCounts? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            free: UInt64(statistics.free_count),
            active: UInt64(statistics.active_count),
            inactive: UInt64(statistics.inactive_count),
            speculative: UInt64(statistics.speculative_count),
            wired: UInt64(statistics.wire_count),
            compressorOccupied: UInt64(statistics.compressor_page_count),
            purgeable: UInt64(statistics.purgeable_count),
            external: UInt64(statistics.external_page_count),
            internal: UInt64(statistics.internal_page_count)
        )
    }

    private static func swapUsage() -> SwapUsage? {
        guard let usage = Sysctl.value("vm.swapusage", as: xsw_usage.self, initial: xsw_usage()) else { return nil }
        return SwapUsage(usedBytes: usage.xsu_used, totalBytes: usage.xsu_total)
    }
}
