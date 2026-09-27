import Accessibility
import Charts
import SwiftUI

/// One plotted value of a live series.
struct LiveChartPoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    /// Points of different segments are never joined (see `TimedSample`).
    let segment: Int
    let value: Double
}

struct LiveChartSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let points: [LiveChartPoint]

    init<Value>(
        id: String,
        label: String,
        color: Color,
        samples: [TimedSample<Value>],
        value: (Value) -> Double
    ) {
        self.id = id
        self.label = label
        self.color = color
        points = samples.map {
            LiveChartPoint(id: $0.id, date: $0.date, segment: $0.segment, value: value($0.value))
        }
    }
}

enum LiveChartStyle: Equatable {
    /// Each series is its own area from zero.
    case area
    /// Series stack on top of each other (parts of a whole).
    case stacked
    /// The first series grows up from zero, the second grows down.
    case mirrored
}

/// Where each point's band starts and ends once the style is applied.
struct LiveChartBandPoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    let segment: Int
    let value: Double
    let lower: Double
    let upper: Double
    /// The y the series' line runs along.
    let edge: Double
    /// Swift Charts groups marks by these keys across the whole chart, so
    /// they carry both the series and the segment: two series never merge
    /// into one line, and a segment never bridges a pause.
    let areaKey: String
    let lineKey: String
}

enum LiveChartBands {
    /// Pure geometry: stacking sums points that share a sample id, mirroring
    /// negates every series after the first.
    static func make(_ series: [[LiveChartPoint]], style: LiveChartStyle) -> [[LiveChartBandPoint]] {
        var running: [Int: Double] = [:]
        return series.enumerated().map { index, points in
            points.map { point in
                let value = max(0, point.value)
                switch style {
                case .area:
                    return band(point, series: index, lower: 0, upper: value, edge: value)
                case .mirrored:
                    return index == 0
                        ? band(point, series: index, lower: 0, upper: value, edge: value)
                        : band(point, series: index, lower: -value, upper: 0, edge: -value)
                case .stacked:
                    let lower = running[point.id] ?? 0
                    let upper = lower + value
                    running[point.id] = upper
                    return band(point, series: index, lower: lower, upper: upper, edge: upper)
                }
            }
        }
    }

    private static func band(
        _ point: LiveChartPoint,
        series: Int,
        lower: Double,
        upper: Double,
        edge: Double
    ) -> LiveChartBandPoint {
        LiveChartBandPoint(
            id: point.id,
            date: point.date,
            segment: point.segment,
            value: point.value,
            lower: lower,
            upper: upper,
            edge: edge,
            areaKey: "area-\(series)#\(point.segment)",
            lineKey: "line-\(series)#\(point.segment)"
        )
    }
}

/// A two-minute scrolling chart in the style of Activity Monitor: no x axis,
/// a quiet trailing y axis, smooth monotone curves, fixed domains so nothing
/// rescales between samples, and a hover readout.
struct LiveChart: View {
    let title: String
    let series: [LiveChartSeries]
    var style: LiveChartStyle = .area
    let window: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    let yTicks: [Double]
    let axisLabel: (Double) -> String
    let valueLabel: (Double) -> String
    var summary: String = ""
    var height: CGFloat = 104

    var body: some View {
        let bands = LiveChartBands.make(series.map(\.points), style: style)
        Group {
            if #available(macOS 15, *) {
                styled(Chart { vectorizedContent(bands) }, bands: bands)
            } else {
                styled(Chart { markContent(bands) }, bands: bands)
            }
        }
        .frame(height: height)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), last two minutes")
        .accessibilityValue(summary)
        .accessibilityChartDescriptor(self)
    }

    /// macOS 15 and later: one vectorized plot per series, which Swift Charts
    /// lays out in a single pass instead of one mark per sample.
    @available(macOS 15, *)
    @ChartContentBuilder
    private func vectorizedContent(_ bands: [[LiveChartBandPoint]]) -> some ChartContent {
        ForEach(series.indices, id: \.self) { index in
            AreaPlot(
                bands[index],
                x: .value("Time", \.date),
                yStart: .value("From", \.lower),
                yEnd: .value("To", \.upper),
                series: .value("Band", \.areaKey)
            )
            .foregroundStyle(fill(for: series[index].color, index: index))
            .interpolationMethod(.monotone)

            LinePlot(
                bands[index],
                x: .value("Time", \.date),
                y: .value(series[index].label, \.edge),
                series: .value("Line", \.lineKey)
            )
            .foregroundStyle(series[index].color)
            .lineStyle(Self.lineStyle)
            .interpolationMethod(.monotone)
        }
        zeroRule
    }

    /// macOS 14: the same picture built from individual marks.
    @ChartContentBuilder
    private func markContent(_ bands: [[LiveChartBandPoint]]) -> some ChartContent {
        ForEach(series.indices, id: \.self) { index in
            let entry = series[index]
            ForEach(bands[index]) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("From", point.lower),
                    yEnd: .value("To", point.upper),
                    series: .value("Band", point.areaKey)
                )
                .foregroundStyle(fill(for: entry.color, index: index))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value(entry.label, point.edge),
                    series: .value("Line", point.lineKey)
                )
                .foregroundStyle(entry.color)
                .lineStyle(Self.lineStyle)
                .interpolationMethod(.monotone)
            }
        }
        zeroRule
    }

    @ChartContentBuilder
    private var zeroRule: some ChartContent {
        if style == .mirrored {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.primary.opacity(0.18))
                .lineStyle(StrokeStyle(lineWidth: 0.75))
        }
    }

    private static let lineStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

    private func styled<Content: ChartContent>(_ chart: Chart<Content>, bands: [[LiveChartBandPoint]]) -> some View {
        chart
            .chartXScale(domain: window)
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(axisLabel(style == .mirrored ? abs(amount) : amount))
                                .font(.system(size: 9.5, weight: .regular, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                // Clip horizontally only: the sample that enters from the left
                // must not spill out, but a 100% line must keep its full stroke.
                plot.mask { Rectangle().padding(.vertical, -4) }
            }
            .chartOverlay { proxy in
                LiveChartHoverLayer(
                    proxy: proxy,
                    series: series,
                    bands: bands,
                    windowEnd: window.upperBound,
                    valueLabel: valueLabel
                )
            }
    }

    private func fill(for color: Color, index: Int) -> AnyShapeStyle {
        switch style {
        case .stacked:
            return AnyShapeStyle(color.opacity(0.26))
        case .mirrored where index > 0:
            return AnyShapeStyle(
                LinearGradient(colors: [color.opacity(0.03), color.opacity(0.28)], startPoint: .top, endPoint: .bottom)
            )
        case .area, .mirrored:
            return AnyShapeStyle(
                LinearGradient(colors: [color.opacity(0.28), color.opacity(0.03)], startPoint: .top, endPoint: .bottom)
            )
        }
    }
}

extension LiveChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let end = window.upperBound
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: -span...0,
            gridlinePositions: []
        ) { SystemStatsFormat.age(-$0) }
        let lower = style == .mirrored ? 0 : yDomain.lowerBound
        let yAxis = AXNumericDataAxisDescriptor(
            title: title,
            range: lower...yDomain.upperBound,
            gridlinePositions: yTicks.filter { $0 >= lower }
        ) { valueLabel($0) }
        let data = series.map { entry in
            AXDataSeriesDescriptor(
                name: entry.label,
                isContinuous: true,
                dataPoints: entry.points.map { point in
                    AXDataPoint(x: point.date.timeIntervalSince(end), y: point.value)
                }
            )
        }
        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: data
        )
    }
}

/// The hover readout, kept in its own view so pointer movement redraws only
/// the rule and the tooltip, never the marks underneath.
private struct LiveChartHoverLayer: View {
    let proxy: ChartProxy
    let series: [LiveChartSeries]
    let bands: [[LiveChartBandPoint]]
    let windowEnd: Date
    let valueLabel: (Double) -> String

    @State private var pointerX: CGFloat?

    private static let tooltipWidth: CGFloat = 164

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let location):
                                pointerX = location.x
                            case .ended:
                                pointerX = nil
                            }
                        }

                    if let pointerX, plot.minX...plot.maxX ~= pointerX,
                       let index = hoveredIndex(pointerX: pointerX, plot: plot),
                       let reference = bands.first?[index],
                       let ruleX = proxy.position(forX: reference.date) {
                        indicator(reference: reference, ruleX: plot.minX + ruleX, plot: plot, size: geometry.size)
                    }
                }
            }
        }
    }

    private func hoveredIndex(pointerX: CGFloat, plot: CGRect) -> Int? {
        guard let points = bands.first, !points.isEmpty,
              let date = proxy.value(atX: pointerX - plot.minX, as: Date.self)
        else { return nil }
        var best = 0
        var bestDistance = TimeInterval.infinity
        for (index, point) in points.enumerated() {
            let distance = abs(point.date.timeIntervalSince(date))
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    @ViewBuilder
    private func indicator(reference: LiveChartBandPoint, ruleX: CGFloat, plot: CGRect, size: CGSize) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.28))
            .frame(width: 1, height: plot.height)
            .offset(x: ruleX - 0.5, y: plot.minY)
            .allowsHitTesting(false)

        ForEach(series.indices, id: \.self) { index in
            if let point = bands[index].first(where: { $0.id == reference.id }),
               let y = proxy.position(forY: point.edge) {
                Circle()
                    .fill(series[index].color)
                    .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5) }
                    .frame(width: 8, height: 8)
                    .offset(x: ruleX - 4, y: plot.minY + y - 4)
                    .allowsHitTesting(false)
            }
        }

        tooltip(for: reference)
            .frame(width: Self.tooltipWidth, alignment: .leading)
            .offset(
                x: tooltipX(ruleX: ruleX, plot: plot, containerWidth: size.width),
                y: plot.minY + 2
            )
            .allowsHitTesting(false)
    }

    private func tooltipX(ruleX: CGFloat, plot: CGRect, containerWidth: CGFloat) -> CGFloat {
        let preferred = ruleX < plot.midX ? ruleX + 10 : ruleX - 10 - Self.tooltipWidth
        return min(max(0, preferred), max(0, containerWidth - Self.tooltipWidth))
    }

    private func tooltip(for reference: LiveChartBandPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SystemStatsFormat.age(windowEnd.timeIntervalSince(reference.date)))
                .font(PortlyTypography.label)
                .foregroundStyle(.secondary)
            ForEach(series.indices, id: \.self) { index in
                if let point = bands[index].first(where: { $0.id == reference.id }) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(series[index].color)
                            .frame(width: 7, height: 7)
                        Text(series[index].label)
                            .font(PortlyTypography.metadata)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(valueLabel(point.value))
                            .font(PortlyTypography.metadata)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
