import Foundation
import IOKit
import IOKit.ps

/// `ProcessInfo.ThermalState`, as a plain value the sampler can hand across
/// threads and the tests can build.
enum SystemThermalState: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

struct BatteryReading: Equatable, Sendable {
    /// Charge, 0...1.
    let level: Double
    let isCharging: Bool
    let isCharged: Bool
    let minutesToEmpty: Int?
    let minutesToFull: Int?
    let cycleCount: Int?
    /// Maximum capacity relative to design, 0...1.
    let health: Double?
}

struct PowerReading: Equatable, Sendable {
    /// Nil on a Mac without a battery.
    let battery: BatteryReading?
    let onExternalPower: Bool
    let adapterWatts: Int?
    /// What the whole machine draws right now, when the battery gauge reports it.
    let systemWatts: Double?
    let thermalState: SystemThermalState
    let lowPowerMode: Bool
}

/// Power source state from the public IOPowerSources API, plus cycle count,
/// health and live power draw from the `AppleSmartBattery` registry entry
/// (the keys exelban/stats and coconutBattery read). Every battery detail is
/// optional: a desktop Mac just shows AC power and the thermal state.
final class PowerStatsReader {
    private var battery: io_service_t = 0

    deinit {
        release()
    }

    func prepare() {
        release()
        battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    func release() {
        if battery != 0 {
            IOObjectRelease(battery)
            battery = 0
        }
    }

    func read() -> PowerReading {
        let source = Self.internalBatteryDescription()
        let state = source?[kIOPSPowerSourceStateKey] as? String
        let onExternalPower = source == nil || state != kIOPSBatteryPowerValue

        var batteryReading: BatteryReading?
        if let source, let current = source[kIOPSCurrentCapacityKey] as? Int {
            let maximum = max(1, source[kIOPSMaxCapacityKey] as? Int ?? 100)
            let batteryData = IORegistry.dictionary(battery, "BatteryData")
            batteryReading = BatteryReading(
                level: min(1, max(0, Double(current) / Double(maximum))),
                isCharging: source[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: source[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToEmpty: Self.minutes(source[kIOPSTimeToEmptyKey]),
                minutesToFull: Self.minutes(source[kIOPSTimeToFullChargeKey]),
                cycleCount: IORegistry.integer(battery, "CycleCount"),
                health: BatteryMath.healthFraction(
                    maximumCapacity: IORegistry.integer(battery, "AppleRawMaxCapacity")
                        ?? (batteryData?["NominalChargeCapacity"] as? NSNumber)?.intValue
                        ?? (batteryData?["FullChargeCapacity"] as? NSNumber)?.intValue,
                    designCapacity: IORegistry.integer(battery, "DesignCapacity")
                        ?? (batteryData?["DesignCapacity"] as? NSNumber)?.intValue
                )
            )
        }

        return PowerReading(
            battery: batteryReading,
            onExternalPower: onExternalPower,
            adapterWatts: onExternalPower ? Self.adapterWatts() : nil,
            systemWatts: systemWatts(discharging: !onExternalPower),
            thermalState: SystemThermalState(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// The gauge's own system-load figure when it publishes one, otherwise
    /// voltage × current while running on battery (on AC the battery current
    /// says nothing about what the machine draws).
    private func systemWatts(discharging: Bool) -> Double? {
        guard battery != 0 else { return nil }
        if let telemetry = IORegistry.dictionary(battery, "PowerTelemetryData"),
           let load = (telemetry["SystemLoad"] as? NSNumber)?.int64Value,
           load > 0, load < 1_000_000 {
            return Double(load) / 1_000
        }
        guard discharging,
              let millivolts = IORegistry.integer(battery, "Voltage"),
              let milliamps = IORegistry.integer(battery, "InstantAmperage") ?? IORegistry.integer(battery, "Amperage")
        else { return nil }
        let watts = abs(BatteryMath.watts(millivolts: millivolts, milliamps: milliamps))
        return watts > 0 && watts < 1_000 ? watts : nil
    }

    private static func internalBatteryDescription() -> [String: Any]? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return description
        }
        return nil
    }

    private static func adapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = details[kIOPSPowerAdapterWattsKey] as? Int, watts > 0
        else { return nil }
        return watts
    }

    /// IOPowerSources reports -1 while it is still estimating.
    private static func minutes(_ value: Any?) -> Int? {
        guard let minutes = value as? Int, minutes > 0, minutes < 60 * 48 else { return nil }
        return minutes
    }
}
