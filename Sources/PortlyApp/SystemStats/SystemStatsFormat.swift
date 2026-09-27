import Foundation

/// Display strings for the "This Mac" cards. Units are joined with a
/// non-breaking space so a value never wraps away from its unit.
enum SystemStatsFormat {
    private static let space = "\u{00A0}"

    /// "42%", or "4.2%" below ten so a quiet machine still reads as non-zero.
    static func percent(_ fraction: Double) -> String {
        let value = max(0, fraction.isFinite ? fraction : 0) * 100
        if value > 0, value < 9.95 {
            return value.formatted(.number.precision(.fractionLength(1))) + "%"
        }
        return value.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    /// Binary units, as Activity Monitor shows memory.
    static func memory(_ bytes: UInt64) -> String {
        byteString(bytes, style: .memory)
    }

    /// Decimal units, as Finder shows disk space and transfers.
    static func storage(_ bytes: UInt64) -> String {
        byteString(bytes, style: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else {
            return byteString(0, style: .file, units: .useKB) + "/s"
        }
        return byteString(UInt64(min(bytesPerSecond, Double(Int64.max))), style: .file) + "/s"
    }

    /// Axis labels: "5 MB/s", "250 KB/s", and a bare "0" at the baseline.
    static func axisRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "0" }
        return rate(bytesPerSecond)
    }

    static func operations(_ perSecond: Double) -> String {
        guard perSecond.isFinite, perSecond >= 0.5 else { return "0" }
        if perSecond >= 10_000 {
            return compactNumber(perSecond / 1_000) + "K"
        }
        return perSecond.formatted(.number.precision(.fractionLength(0)))
    }

    static func watts(_ value: Double) -> String {
        let digits = value < 10 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits))) + space + "W"
    }

    /// Axis labels for a memory chart plotted in GiB.
    static func axisMemory(gibibytes value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        return memory(UInt64(value * 1_073_741_824))
    }

    /// Temperature in the unit this Mac's region uses.
    static func temperature(_ celsius: Double, fahrenheit: Bool) -> String {
        let value = fahrenheit ? displayTemperature(celsius, fahrenheit: true) : celsius
        return value.formatted(.number.precision(.fractionLength(0))) + space + (fahrenheit ? "°F" : "°C")
    }

    static func displayTemperature(_ celsius: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    static var prefersFahrenheit: Bool {
        Locale.current.measurementSystem == .us
    }

    /// "3 d 4 h", "5 h 12 m", "12 m", "40 s".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0\(space)s" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)\(space)d \(hours)\(space)h" }
        if hours > 0 { return "\(hours)\(space)h \(minutes)\(space)m" }
        if minutes > 0 { return "\(minutes)\(space)m" }
        return "\(total)\(space)s"
    }

    /// "now", "12 s ago", "1 m 20 s ago".
    static func age(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 1 { return "now" }
        if total < 60 { return "\(total)\(space)s ago" }
        let remainder = total % 60
        return remainder == 0
            ? "\(total / 60)\(space)m ago"
            : "\(total / 60)\(space)m \(remainder)\(space)s ago"
    }

    /// Axis tick numbers: "12", "2.5".
    static func axisNumber(_ value: Double) -> String {
        compactNumber(value)
    }

    private static func compactNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 && value.rounded() != value ? 1 : 0)))
    }

    private static func byteString(
        _ bytes: UInt64,
        style: ByteCountFormatter.CountStyle,
        units: ByteCountFormatter.Units = []
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowedUnits = units
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
            .replacingOccurrences(of: " ", with: space)
    }
}
