import Darwin
import Foundation
import IOKit

/// Thin, failure-tolerant wrappers over `sysctl`. Every reader treats a
/// missing key as "not available on this Mac", never as an error.
enum Sysctl {
    static func integer(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size:
            // The kernel wrote four bytes into the low half.
            return Int(Int32(truncatingIfNeeded: value))
        case MemoryLayout<Int64>.size:
            return Int(value)
        default:
            return nil
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// A fixed-size C struct (`timeval`, `xsw_usage`).
    static func value<T: BitwiseCopyable>(_ name: String, as type: T.Type, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            sysctlbyname(name, buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }
}

/// IORegistry property access. Every `Create`/`Copy` result is balanced by
/// taking the retained value, and every `io_object_t` handed out by these
/// helpers must be released by the caller.
enum IORegistry {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard entry != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    static func integer(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func dictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        property(entry, key) as? [String: Any]
    }

    /// Strings in the registry are sometimes NUL-terminated `Data`.
    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        switch property(entry, key) {
        case let string as String:
            return string.isEmpty ? nil : string
        case let data as Data:
            let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    /// Every service currently matching `className`. The caller owns them.
    static func services(matching className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        return services
    }

    static func release(_ objects: [io_object_t]) {
        for object in objects where object != 0 {
            IOObjectRelease(object)
        }
    }

    static func registryID(_ entry: io_registry_entry_t) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &identifier) == KERN_SUCCESS else { return nil }
        return identifier
    }

    static func className(_ object: io_object_t) -> String? {
        guard let name = IOObjectCopyClass(object)?.takeRetainedValue() else { return nil }
        return name as String
    }
}

extension NSNumber {
    /// Registry counters are unsigned 64-bit but travel as signed CFNumbers.
    var registryCounter: UInt64 { UInt64(bitPattern: int64Value) }
}
