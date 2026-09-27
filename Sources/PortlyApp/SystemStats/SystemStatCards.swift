import SwiftUI

// The seven "This Mac" cards. Each observes only its own feed, so a card
// redraws when its numbers change and never because another card did.

private enum SystemCardMetrics {
    static let gibibyte = 1_073_741_824.0

    static func window(endingAt end: Date) -> ClosedRange<Date> {
        end.addingTimeInterval(-SystemStatsSampler.window)...end
    }

    static func loadAverage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

extension MemoryPressureLevel {
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

extension SystemThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }

    var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - CPU

struct CPUStatCard: View {
    @ObservedObject var feed: SystemStatsFeed<CPUCardState>

    var body: some View {
        SystemStatCard(title: "CPU", icon: .cpu, tint: .purple, caption: feed.state?.description.chipName) {
            if let state = feed.state, let current = state.current {
                content(state: state, current: current)
            } else {
                SystemCardPlaceholder()
            }
        }
    }

    @ViewBuilder
    private func content(state: CPUCardState, current: CPUReading) -> some View {
        let usage = current.usage
        SystemHeadline(
            value: SystemStatsFormat.percent(usage.total),
            detail: "busy across \(state.description.logicalCPUCount) cores"
        )

        SystemLegend(items: [
            SystemLegendItem(label: "User", value: SystemStatsFormat.percent(usage.user), color: SystemStatsPalette.primary),
            SystemLegendItem(label: "System", value: SystemStatsFormat.percent(usage.system), color: SystemStatsPalette.secondary),
        ])

        LiveChart(
            title: "CPU usage",
            series: [
                LiveChartSeries(id: "user", label: "User", color: SystemStatsPalette.primary, samples: state.history) { $0.user * 100 },
                LiveChartSeries(id: "system", label: "System", color: SystemStatsPalette.secondary, samples: state.history) { $0.system * 100 },
            ],
            style: .stacked,
            window: SystemCardMetrics.window(endingAt: state.windowEnd),
            yDomain: 0...100,
            yTicks: [0, 50, 100],
            axisLabel: { "\(Int($0.rounded()))%" },
            valueLabel: { SystemStatsFormat.percent($0 / 100) },
            summary: "\(SystemStatsFormat.percent(usage.total)) busy: user \(SystemStatsFormat.percent(usage.user)), system \(SystemStatsFormat.percent(usage.system))"
        )

        CoreLoadBars(groups: state.description.groups, perCore: current.perCore, tint: .purple)

        SystemStatStrip(items: statItems(state))
    }

    private func statItems(_ state: CPUCardState) -> [SystemStatItem] {
        var items: [SystemStatItem] = []
        if let load = state.loadAverage, load.count == 3 {
            items.append(SystemStatItem(label: "Load 1 min", value: SystemCardMetrics.loadAverage(load[0])))
            items.append(SystemStatItem(label: "Load 5 min", value: SystemCardMetrics.loadAverage(load[1])))
            items.append(SystemStatItem(label: "Load 15 min", value: SystemCardMetrics.loadAverage(load[2])))
        }
        if let uptime = state.uptime {
            items.append(SystemStatItem(label: "Uptime", value: SystemStatsFormat.duration(uptime)))
        }
        return items
    }
}

// MARK: - Memory

struct MemoryStatCard: View {
    @ObservedObject var feed: SystemStatsFeed<MemoryCardState>

    private static let appColor = SystemStatsPalette.primary
    private static let wiredColor = SystemStatsPalette.secondary
    private static let compressedColor = SystemStatsPalette.tertiary
    private static let cachedColor = Color.gray.opacity(0.55)

    var body: some View {
        SystemStatCard(
            title: "Memory",
            icon: .memory,
            tint: .blue,
            caption: feed.state.map { SystemStatsFormat.memory($0.current.breakdown.totalBytes) }
        ) {
            if let state = feed.state {
                content(state)
            } else {
                SystemCardPlaceholder()
            }
        }
    }

    @ViewBuilder
    private func content(_ state: MemoryCardState) -> some View {
        let memory = state.current.breakdown
        let total = Double(max(1, memory.totalBytes))
        let totalGiB = total / SystemCardMetrics.gibibyte

        HStack(alignment: .firstTextBaseline) {
            SystemHeadline(
                value: SystemStatsFormat.memory(memory.usedBytes),
                detail: "used · \(SystemStatsFormat.percent(memory.usedFraction))"
            )
            Spacer(minLength: 8)
            SystemStatusPill(label: "Pressure \(state.current.pressure.label)", color: state.current.pressure.color)
                .help("Memory pressure as macOS reports it")
        }

        SystemCompositionBar(segments: [
            SystemBarSegment(id: "app", fraction: Double(memory.appBytes) / total, color: Self.appColor),
            SystemBarSegment(id: "wired", fraction: Double(memory.wiredBytes) / total, color: Self.wiredColor),
            SystemBarSegment(id: "compressed", fraction: Double(memory.compressedBytes) / total, color: Self.compressedColor),
            SystemBarSegment(id: "cached", fraction: Double(memory.cachedBytes) / total, color: Self.cachedColor),
        ])

        SystemLegend(items: [
            SystemLegendItem(label: "App", value: SystemStatsFormat.memory(memory.appBytes), color: Self.appColor),
            SystemLegendItem(label: "Wired", value: SystemStatsFormat.memory(memory.wiredBytes), color: Self.wiredColor),
            SystemLegendItem(label: "Compressed", value: SystemStatsFormat.memory(memory.compressedBytes), color: Self.compressedColor),
            SystemLegendItem(label: "Cached", value: SystemStatsFormat.memory(memory.cachedBytes), color: Self.cachedColor),
        ])

        LiveChart(
            title: "Memory used",
            series: [
                LiveChartSeries(id: "app", label: "App", color: Self.appColor, samples: state.history) {
                    Double($0.appBytes) / SystemCardMetrics.gibibyte
                },
                LiveChartSeries(id: "wired", label: "Wired", color: Self.wiredColor, samples: state.history) {
                    Double($0.wiredBytes) / SystemCardMetrics.gibibyte
                },
                LiveChartSeries(id: "compressed", label: "Compressed", color: Self.compressedColor, samples: state.history) {
                    Double($0.compressedBytes) / SystemCardMetrics.gibibyte
                },
            ],
            style: .stacked,
            window: SystemCardMetrics.window(endingAt: state.windowEnd),
            yDomain: 0...totalGiB,
            yTicks: [0, totalGiB / 2, totalGiB],
            axisLabel: { SystemStatsFormat.axisMemory(gibibytes: $0) },
            valueLabel: { SystemStatsFormat.memory(UInt64(max(0, $0) * SystemCardMetrics.gibibyte)) },
            summary: "\(SystemStatsFormat.memory(memory.usedBytes)) of \(SystemStatsFormat.memory(memory.totalBytes)) used, pressure \(state.current.pressure.label)"
        )

        SystemStatStrip(items: [
            SystemStatItem(label: "Available", value: SystemStatsFormat.memory(memory.freeBytes + memory.cachedBytes)),
            SystemStatItem(label: "Free", value: SystemStatsFormat.memory(memory.freeBytes)),
            SystemStatItem(label: "Swap used", value: swapDescription(state.current.swap)),
        ])
    }

    private func swapDescription(_ swap: SwapUsage?) -> String {
        guard let swap else { return "—" }
        guard swap.totalBytes > 0 else { return "None" }
        return SystemStatsFormat.memory(swap.usedBytes)
    }
}

// MARK: - GPU

struct GPUStatCard: View {
    @ObservedObject var feed: SystemStatsFeed<GPUCardState>

    var body: some View {
        SystemStatCard(title: "GPU", icon: .cube, tint: .teal, caption: caption) {
            if let state = feed.state {
                content(state)
            } else {
                SystemCardPlaceholder()
            }
        }
    }

    private var caption: String? {
        guard let description = feed.state?.description else { return nil }
        return [description.name, description.coreCount.map { "\($0) cores" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ state: GPUCardState) -> some View {
        let current = state.current
        SystemHeadline(value: SystemStatsFormat.percent(current.deviceUtilization), detail: "utilization")

        LiveChart(
            title: "GPU utilization",
            series: [
                LiveChartSeries(id: "device", label: "Utilization", color: SystemStatsPalette.gpu, samples: state.history) { $0 * 100 },
            ],
            window: SystemCardMetrics.window(endingAt: state.windowEnd),
            yDomain: 0...100,
            yTicks: [0, 50, 100],
            axisLabel: { "\(Int($0.rounded()))%" },
            valueLabel: { SystemStatsFormat.percent($0 / 100) },
            summary: "\(SystemStatsFormat.percent(current.deviceUtilization)) utilization"
        )

        SystemStatStrip(items: statItems(current))
    }

    private func statItems(_ current: GPUReading) -> [SystemStatItem] {
        var items: [SystemStatItem] = []
        if let renderer = current.rendererUtilization {
            items.append(SystemStatItem(label: "Renderer", value: SystemStatsFormat.percent(renderer)))
        }
        if let tiler = current.tilerUtilization {
            items.append(SystemStatItem(label: "Tiler", value: SystemStatsFormat.percent(tiler)))
        }
        if let memory = current.memoryInUseBytes {
            items.append(SystemStatItem(label: "Memory in use", value: SystemStatsFormat.memory(memory)))
        }
        return items
    }
}

// MARK: - Network

struct NetworkStatCard: View {
    @ObservedObject var feed: SystemStatsFeed<NetworkCardState>

    var body: some View {
        SystemStatCard(title: "Network", icon: icon, tint: .cyan, caption: caption) {
            if let state = feed.state, let current = state.current {
                content(state, current: current)
            } else {
                SystemCardPlaceholder()
            }
        }
    }

    private var icon: AppIcon {
        feed.state?.interfaces.first?.localizedCaseInsensitiveContains("Wi-Fi") == true ? .wifi : .network
    }

    private var caption: String? {
        guard let interfaces = feed.state?.interfaces, let first = interfaces.first else { return nil }
        return interfaces.count > 1 ? "\(first) + \(interfaces.count - 1)" : first
    }

    @ViewBuilder
    private func content(_ state: NetworkCardState, current: PairedRate) -> some View {
        TransferHeadlines(
            primary: ("Download", current.primary),
            secondary: ("Upload", current.secondary)
        )

        LiveChart(
            title: "Network throughput",
            series: [
                LiveChartSeries(id: "down", label: "Download", color: SystemStatsPalette.primary, samples: state.history) { $0.primary },
                LiveChartSeries(id: "up", label: "Upload", color: SystemStatsPalette.secondary, samples: state.history) { $0.secondary },
            ],
            style: .mirrored,
            window: SystemCardMetrics.window(endingAt: state.windowEnd),
            yDomain: -state.axisCeiling...state.axisCeiling,
            yTicks: [-state.axisCeiling, 0, state.axisCeiling],
            axisLabel: { SystemStatsFormat.axisRate($0) },
            valueLabel: { SystemStatsFormat.rate($0) },
            summary: "Download \(SystemStatsFormat.rate(current.primary)), upload \(SystemStatsFormat.rate(current.secondary))"
        )

        SystemStatStrip(items: [
            SystemStatItem(label: "Received", value: SystemStatsFormat.storage(state.totalReceived), tint: SystemStatsPalette.primary),
            SystemStatItem(label: "Sent", value: SystemStatsFormat.storage(state.totalSent), tint: SystemStatsPalette.secondary),
            SystemStatItem(label: "Peak down", value: SystemStatsFormat.rate(state.peak.primary)),
            SystemStatItem(label: "Peak up", value: SystemStatsFormat.rate(state.peak.secondary)),
        ])
    }
}

// MARK: - Disk

struct DiskStatCard: View {
    @ObservedObject var feed: SystemStatsFeed<DiskCardState>

    var body: some View {
        SystemStatCard(title: "Disk", icon: .hardDrive, tint: .indigo, caption: feed.state?.volume?.name) {
            if let state = feed.state, let current = state.current {
                content(state, current: current)
            } else {
                SystemCardPlaceholder()
            }
        }
    }

    @ViewBuilder
    private func content(_ state: DiskCardState, current: PairedRate) -> some View {
        TransferHeadlines(
            primary: ("Read", current.primary),
            secondary: ("Write", current.secondary)
        )

        LiveChart(
            title: "Disk throughput",
            series: [
                LiveChartSeries(id: "read", label: "Read", color: SystemStatsPalette.primary, samples: state.history) { $0.primary },
                LiveChartSeries(id: "write", label: "Write", color: SystemStatsPalette.secondary, samples: state.history) { $0.secondary },
            ],
            style: .mirrored,
            window: SystemCardMetrics.window(endingAt: state.windowEnd),
            yDomain: -state.axisCeiling...state.axisCeiling,
            yTicks: [-state.axisCeiling, 0, state.axisCeiling],
            axisLabel: { SystemStatsFormat.axisRate($0) },
            valueLabel: { SystemStatsFormat.rate($0) },
            summary: "Read \(SystemStatsFormat.rate(current.primary)), write \(SystemStatsFormat.rate(current.secondary))"
        )

        if let volume = state.volume {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(volume.name)
                        .font(PortlyTypography.bodyMedium)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(SystemStatsFormat.storage(volume.availableBytes)) available of \(SystemStatsFormat.storage(volume.totalBytes))")
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                SystemCompositionBar(segments: [
                    SystemBarSegment(id: "used", fraction: volume.usedFraction, color: volume.usedFraction > 0.9 ? .orange : .indigo),
                ])
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(volume.name) storage")
            .accessibilityValue(
                "\(SystemStatsFormat.storage(volume.availableBytes)) available of \(SystemStatsFormat.storage(volume.totalBytes))"
            )
        }

        SystemStatStrip(items: [
            SystemStatItem(label: "Read", value: SystemStatsFormat.storage(state.totalRead), tint: SystemStatsPalette.primary),
            SystemStatItem(label: "Written", value: SystemStatsFormat.storage(state.totalWritten), tint: SystemStatsPalette.secondary),
            SystemStatItem(label: "Reads/s", value: SystemStatsFormat.operations(state.operations?.primary ?? 0)),
            SystemStatItem(label: "Writes/s", value: SystemStatsFormat.operations(state.operations?.secondary ?? 0)),
        ])
    }
}

/// Download/upload or read/write side by side, each with its swatch.
private struct TransferHeadlines: View {
    let primary: (label: String, rate: Double)
    let secondary: (label: String, rate: Double)

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            block(primary.label, rate: primary.rate, color: SystemStatsPalette.primary)
            block(secondary.label, rate: secondary.rate, color: SystemStatsPalette.secondary)
            Spacer(minLength: 0)
        }
    }

    private func block(_ label: String, rate: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(label)
                    .font(PortlyTypography.bodyMedium)
                    .foregroundStyle(.secondary)
            }
            Text(SystemStatsFormat.rate(rate))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(SystemStatsFormat.rate(rate))
    }
}

// MARK: - Temperatures

struct ThermalStatCard: View {
    @ObservedObject var feed: SystemStatsFeed<ThermalCardState>

    private let fahrenheit = SystemStatsFormat.prefersFahrenheit

    var body: some View {
        SystemStatCard(
            title: "Temperatures",
            icon: .temperature,
            tint: .orange,
            caption: feed.state.map { "\($0.current.dieSensorCount) chip sensors" }
        ) {
            if let state = feed.state {
                content(state)
            } else {
                SystemCardPlaceholder()
            }
        }
    }

    @ViewBuilder
    private func content(_ state: ThermalCardState) -> some View {
        let current = state.current
        HStack(alignment: .firstTextBaseline) {
            SystemHeadline(value: temperature(current.averageDie), detail: "chip average")
            Spacer(minLength: 8)
            if let thermalState = state.thermalState {
                SystemStatusPill(label: "Thermal \(thermalState.label)", color: thermalState.color)
                    .help("Thermal pressure as macOS reports it")
            }
        }

        SystemLegend(items: [
            SystemLegendItem(label: "Average", value: temperature(current.averageDie), color: SystemStatsPalette.heat),
            SystemLegendItem(label: "Hottest", value: temperature(current.hottestDie), color: SystemStatsPalette.hottest),
        ])

        let lower = SystemStatsFormat.displayTemperature(state.axisRange.lowerBound, fahrenheit: fahrenheit)
        let upper = SystemStatsFormat.displayTemperature(state.axisRange.upperBound, fahrenheit: fahrenheit)
        LiveChart(
            title: "Chip temperature",
            series: [
                LiveChartSeries(id: "hottest", label: "Hottest", color: SystemStatsPalette.hottest, samples: state.history) {
                    SystemStatsFormat.displayTemperature($0.hottestDie, fahrenheit: fahrenheit)
                },
                LiveChartSeries(id: "average", label: "Average", color: SystemStatsPalette.heat, samples: state.history) {
                    SystemStatsFormat.displayTemperature($0.averageDie, fahrenheit: fahrenheit)
                },
            ],
            window: SystemCardMetrics.window(endingAt: state.windowEnd),
            yDomain: lower...upper,
            yTicks: [lower, (lower + upper) / 2, upper],
            axisLabel: { "\(Int($0.rounded()))°" },
            valueLabel: { "\(Int($0.rounded()))\u{00A0}\(fahrenheit ? "°F" : "°C")" },
            summary: "Chip average \(temperature(current.averageDie)), hottest \(temperature(current.hottestDie))"
        )

        SystemStatStrip(items: statItems(current))
    }

    private func statItems(_ current: ThermalSummary) -> [SystemStatItem] {
        var items = [SystemStatItem(label: "Hottest", value: temperature(current.hottestDie))]
        if let storage = current.storage {
            items.append(SystemStatItem(label: "SSD", value: temperature(storage)))
        }
        if let battery = current.battery {
            items.append(SystemStatItem(label: "Battery", value: temperature(battery)))
        }
        return items
    }

    private func temperature(_ celsius: Double) -> String {
        SystemStatsFormat.temperature(celsius, fahrenheit: fahrenheit)
    }
}

// MARK: - Power

struct PowerStatCard: View {
    @ObservedObject var feed: SystemStatsFeed<PowerCardState>
    /// False when the Temperatures card already shows the thermal state.
    let showsThermalState: Bool

    var body: some View {
        SystemStatCard(
            title: "Power",
            icon: feed.state?.current.battery == nil ? .bolt : .battery,
            tint: .green,
            caption: feed.state.map { source($0.current) }
        ) {
            if let state = feed.state {
                content(state)
            } else {
                SystemCardPlaceholder()
            }
        }
    }

    private func source(_ power: PowerReading) -> String {
        guard power.onExternalPower else { return "On battery" }
        if let watts = power.adapterWatts { return "Power adapter · \(watts) W" }
        return power.battery == nil ? "AC power" : "Power adapter"
    }

    @ViewBuilder
    private func content(_ state: PowerCardState) -> some View {
        let power = state.current
        HStack(alignment: .firstTextBaseline) {
            if let battery = power.battery {
                SystemHeadline(value: SystemStatsFormat.percent(battery.level), detail: batteryStatus(battery, power: power))
            } else if let watts = power.systemWatts {
                SystemHeadline(value: SystemStatsFormat.watts(watts), detail: "system power")
            } else {
                SystemHeadline(value: "AC", detail: "no battery")
            }
            Spacer(minLength: 8)
            if showsThermalState {
                SystemStatusPill(label: "Thermal \(power.thermalState.label)", color: power.thermalState.color)
                    .help("Thermal pressure as macOS reports it")
            }
        }

        if let battery = power.battery {
            SystemCompositionBar(segments: [
                SystemBarSegment(id: "charge", fraction: battery.level, color: chargeColor(battery.level)),
            ])
            .accessibilityHidden(true)
        }

        if !state.history.isEmpty {
            LiveChart(
                title: "System power",
                series: [
                    LiveChartSeries(id: "watts", label: "System power", color: SystemStatsPalette.power, samples: state.history) { $0 },
                ],
                window: SystemCardMetrics.window(endingAt: state.windowEnd),
                yDomain: 0...state.axisCeiling,
                yTicks: [0, state.axisCeiling / 2, state.axisCeiling],
                axisLabel: { "\(SystemStatsFormat.axisNumber($0))\u{00A0}W" },
                valueLabel: { SystemStatsFormat.watts($0) },
                summary: power.systemWatts.map { "Drawing \(SystemStatsFormat.watts($0))" } ?? ""
            )
        }

        SystemStatStrip(items: statItems(power))
    }

    private func batteryStatus(_ battery: BatteryReading, power: PowerReading) -> String {
        if battery.isCharging {
            return battery.minutesToFull.map { "charging · \(SystemStatsFormat.duration(TimeInterval($0 * 60))) to full" } ?? "charging"
        }
        if power.onExternalPower {
            return battery.isCharged || battery.level >= 0.995 ? "charged" : "not charging"
        }
        return battery.minutesToEmpty.map { "\(SystemStatsFormat.duration(TimeInterval($0 * 60))) left" } ?? "on battery"
    }

    private func chargeColor(_ level: Double) -> Color {
        if level <= 0.1 { return .red }
        if level <= 0.2 { return .orange }
        return .green
    }

    private func statItems(_ power: PowerReading) -> [SystemStatItem] {
        var items: [SystemStatItem] = []
        if power.battery != nil, let watts = power.systemWatts {
            items.append(SystemStatItem(label: "Drawing", value: SystemStatsFormat.watts(watts)))
        }
        if let cycles = power.battery?.cycleCount {
            items.append(SystemStatItem(label: "Cycles", value: "\(cycles)"))
        }
        if let health = power.battery?.health {
            items.append(SystemStatItem(label: "Health", value: SystemStatsFormat.percent(health)))
        }
        items.append(SystemStatItem(label: "Low Power", value: power.lowPowerMode ? "On" : "Off"))
        return items
    }
}
