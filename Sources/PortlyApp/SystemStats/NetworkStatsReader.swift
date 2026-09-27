import Darwin
import Foundation
import SystemConfiguration

/// Cumulative byte counters of the physical interfaces, keyed by BSD name.
struct NetworkCounters: Equatable, Sendable {
    var received: [String: UInt64]
    var sent: [String: UInt64]
    /// 64 from the routing sysctl, 32 from the `getifaddrs` fallback.
    var bitWidth: Int
}

/// Wire traffic of every physical interface (Wi-Fi, Ethernet, USB and
/// Thunderbolt adapters: the `en*` family).
///
/// Tunnels, bridges, loopback and AWDL are left out on purpose: a VPN's bytes
/// already cross the physical link once, and counting `utun` as well would
/// double them. Counters come from `NET_RT_IFLIST2` (64-bit, as in
/// exelban/stats), falling back to `getifaddrs`, whose `if_data` counters are
/// 32-bit and wrap every 4 GiB; the rate math absorbs both.
final class NetworkStatsReader {
    private var namesByIndex: [UInt32: String] = [:]
    private var displayNames: [String: String] = [:]
    private var readsSinceNameRefresh = 0

    func read() -> NetworkCounters? {
        readsSinceNameRefresh += 1
        if readsSinceNameRefresh >= 30 {
            // Interface indexes can be reused after an adapter is unplugged.
            namesByIndex = [:]
            readsSinceNameRefresh = 0
        }
        return routingCounters() ?? interfaceAddressCounters()
    }

    /// "Wi-Fi", "Thunderbolt Ethernet Slot 1", or the BSD name.
    func displayName(for bsdName: String) -> String {
        if let known = displayNames[bsdName] { return known }
        refreshDisplayNames()
        let name = displayNames[bsdName] ?? bsdName
        displayNames[bsdName] = name
        return name
    }

    static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en")
    }

    // MARK: - Routing sysctl (64-bit counters)

    private func routingCounters() -> NetworkCounters? {
        guard let buffer = Self.interfaceList() else { return nil }
        var counters = NetworkCounters(received: [:], sent: [:], bitWidth: 64)
        let headerSize = MemoryLayout<if_msghdr>.size
        let infoSize = MemoryLayout<if_msghdr2>.size

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + headerSize <= raw.count {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0 else { break }
                defer { offset += length }

                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + infoSize <= raw.count
                else { continue }
                let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard info.ifm_flags & IFF_UP != 0,
                      info.ifm_flags & IFF_LOOPBACK == 0,
                      let name = interfaceName(index: UInt32(info.ifm_index)),
                      Self.isPhysical(name)
                else { continue }
                counters.received[name] = info.ifm_data.ifi_ibytes
                counters.sent[name] = info.ifm_data.ifi_obytes
            }
        }
        return counters
    }

    private static func interfaceList() -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // The table can grow between sizing and reading; retry a couple of times.
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
            length += 2_048
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 {
                return Array(buffer.prefix(length))
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    private func interfaceName(index: UInt32) -> String? {
        if let name = namesByIndex[index] { return name }
        refreshNames()
        return namesByIndex[index]
    }

    private func refreshNames() {
        guard let list = if_nameindex() else { return }
        defer { if_freenameindex(list) }
        var names: [UInt32: String] = [:]
        var entry = list
        while entry.pointee.if_index != 0, let name = entry.pointee.if_name {
            names[entry.pointee.if_index] = String(cString: name)
            entry += 1
        }
        namesByIndex = names
    }

    // MARK: - getifaddrs fallback (32-bit counters)

    private func interfaceAddressCounters() -> NetworkCounters? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var counters = NetworkCounters(received: [:], sent: [:], bitWidth: 32)
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let data = entry.pointee.ifa_data
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard Self.isPhysical(name) else { continue }
            let linkData = data.assumingMemoryBound(to: if_data.self).pointee
            counters.received[name] = UInt64(linkData.ifi_ibytes)
            counters.sent[name] = UInt64(linkData.ifi_obytes)
        }
        return counters
    }

    // MARK: - Display names

    private func refreshDisplayNames() {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            displayNames[bsdName] = display
        }
    }
}
