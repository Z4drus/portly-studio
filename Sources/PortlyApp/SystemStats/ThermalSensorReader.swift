import Darwin
import Foundation
import IOKit.hidsystem

/// Apple silicon temperature sensors, read through the HID event system the
/// way exelban/stats does.
///
/// This is the one place the dashboard leans on private API: listing the
/// sensors is public (`IOHIDEventSystemClientCopyServices`,
/// `IOHIDServiceClientConformsTo`, `IOHIDServiceClientCopyProperty`), but a
/// client allowed to read values (`IOHIDEventSystemClientCreate`) and the value
/// itself (`IOHIDServiceClientCopyEvent`, `IOHIDEventGetFloatValue`) are not
/// in the SDK headers. So the reader fails closed at every step: symbols are
/// resolved with `dlsym` and a missing one disables it, implausible values are
/// dropped, and a sweep that keeps coming back empty or turns slow switches it
/// off for the session. A disabled reader simply hides the Temperatures card.
final class ThermalSensorReader {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
    private typealias CopyEvent = @convention(c) (IOHIDServiceClient, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValue = @convention(c) (CFTypeRef, UInt32) -> Double

    /// `kIOHIDEventTypeTemperature` and the first field of that event.
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField = UInt32(15 << 16)
    /// Vendor usage page / usage of the temperature sensors.
    private static let sensorUsagePage: UInt32 = 0xFF00
    private static let sensorUsage: UInt32 = 5
    /// A sweep slower than this is not worth its cost on a dashboard.
    private static let slowSweep: TimeInterval = 0.4

    private struct Sensor {
        let service: IOHIDServiceClient
        let name: String
    }

    private var client: IOHIDEventSystemClient?
    private var sensors: [Sensor] = []
    private var copyEvent: CopyEvent?
    private var getFloatValue: GetFloatValue?
    private var emptySweeps = 0
    private var slowSweeps = 0
    private(set) var isDisabled = false

    /// Resolves the private entry points and lists the sensors worth reading.
    /// False when this Mac (or this macOS) does not offer them.
    func prepare() -> Bool {
        guard !isDisabled else { return false }
        #if arch(arm64)
        if client == nil {
            guard let handle = dlopen(nil, RTLD_NOW),
                  let createSymbol = dlsym(handle, "IOHIDEventSystemClientCreate"),
                  let copySymbol = dlsym(handle, "IOHIDServiceClientCopyEvent"),
                  let floatSymbol = dlsym(handle, "IOHIDEventGetFloatValue")
            else { return disable() }
            let create = unsafeBitCast(createSymbol, to: CreateClient.self)
            copyEvent = unsafeBitCast(copySymbol, to: CopyEvent.self)
            getFloatValue = unsafeBitCast(floatSymbol, to: GetFloatValue.self)
            guard let created = create(kCFAllocatorDefault)?.takeRetainedValue() else { return disable() }
            client = created
        }
        guard let client,
              let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
        else { return disable() }
        sensors = services.compactMap { service in
            guard IOHIDServiceClientConformsTo(service, Self.sensorUsagePage, Self.sensorUsage) != 0,
                  let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                  ThermalSensorMath.category(for: name) != nil
            else { return nil }
            return Sensor(service: service, name: name)
        }
        return sensors.isEmpty ? disable() : true
        #else
        // Intel Macs expose temperatures only through the SMC; not attempted.
        return disable()
        #endif
    }

    /// Nil when nothing plausible came back; repeated failures disable the reader.
    func read() -> ThermalSummary? {
        guard !isDisabled, let copyEvent, let getFloatValue, !sensors.isEmpty else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        var readings: [ThermalReading] = []
        readings.reserveCapacity(sensors.count)
        for sensor in sensors {
            guard let event = copyEvent(sensor.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else {
                continue
            }
            let value = getFloatValue(event, Self.temperatureField)
            guard value.isFinite else { continue }
            readings.append(ThermalReading(name: sensor.name, celsius: value))
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - started
        slowSweeps = elapsed > Self.slowSweep ? slowSweeps + 1 : 0
        let summary = ThermalSensorMath.summarize(readings)
        emptySweeps = summary == nil ? emptySweeps + 1 : 0
        if slowSweeps >= 3 || emptySweeps >= 3 {
            _ = disable()
        }
        return summary
    }

    /// Drops the sensor list; the client is kept for a cheaper restart.
    func release() {
        sensors = []
    }

    @discardableResult
    private func disable() -> Bool {
        isDisabled = true
        sensors = []
        client = nil
        return false
    }
}
