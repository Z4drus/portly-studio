import AppKit
import SwiftUI

/// Series colors shared by every "This Mac" card. The primary/secondary pair
/// is the same everywhere (download/read/user in blue, upload/write/system in
/// orange), so the section reads as one system.
enum SystemStatsPalette {
    static let primary = Color.blue
    static let secondary = Color.orange
    static let tertiary = Color.purple
    static let neutral = Color.secondary
    static let gpu = Color.teal
    static let power = Color.green
    static let heat = Color.orange
    static let hottest = Color.red
}

// MARK: - Card chrome

/// The card every "This Mac" metric lives in: same material, radius and
/// stroke as the dashboard's other panels, with a tinted glyph tile.
struct SystemStatCard<Content: View>: View {
    let title: String
    let icon: AppIcon
    let tint: Color
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                NucleoIconView(icon, size: 14)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(PortlyTypography.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let caption {
                    Text(caption)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(caption)
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Shown for the second it takes a rate to have two readings to compare.
struct SystemCardPlaceholder: View {
    var height: CGFloat = 200

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Collecting…")
                .font(PortlyTypography.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: height)
    }
}

/// The big number of a card, with an optional unit-like suffix.
struct SystemHeadline: View {
    let value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(PortlyTypography.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Swatch, label and current value: identity never rests on color alone.
struct SystemLegendItem: View {
    let label: String
    let value: String?
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label)
                .font(PortlyTypography.bodyMedium)
                .lineLimit(1)
            if let value {
                Text(value)
                    .font(PortlyTypography.metric)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(label), \($0)" } ?? label)
    }
}

/// A row of legend items that folds into two columns when the card is narrow.
struct SystemLegend: View {
    let items: [SystemLegendItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { $0.element }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                    GridRow {
                        items[start]
                        if start + 1 < items.count {
                            items[start + 1]
                        }
                    }
                }
            }
        }
    }
}

/// One secondary figure under a chart: a small label over a monospaced value.
struct SystemStatItem: Identifiable {
    let label: String
    let value: String
    var tint: Color?

    var id: String { label }
}

/// Up to four figures in a row, two by two when the card is narrow.
struct SystemStatStrip: View {
    let items: [SystemStatItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(items) { item in
                    cell(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                    GridRow {
                        cell(items[start])
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if start + 1 < items.count {
                            cell(items[start + 1])
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func cell(_ item: SystemStatItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.label.uppercased())
                .font(PortlyTypography.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                if let tint = item.tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(item.value)
                    .font(PortlyTypography.metric)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label), \(item.value)")
    }
}

/// A status capsule (memory pressure, thermal state): color plus a word,
/// never color alone.
struct SystemStatusPill: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label)
                .font(PortlyTypography.label)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(color.opacity(0.12), in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.75) }
        .fixedSize()
    }
}

// MARK: - Composition bar

struct SystemBarSegment: Identifiable {
    let id: String
    let fraction: Double
    let color: Color
}

/// A single horizontal part-to-whole bar (memory composition, disk space,
/// battery charge). A 2 pt gap separates the parts instead of borders.
struct SystemCompositionBar: View {
    let segments: [SystemBarSegment]
    var height: CGFloat = 8
    var trackColor = Color.primary.opacity(0.07)

    var body: some View {
        GeometryReader { geometry in
            let visible = segments.filter { $0.fraction > 0.002 }
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            let usable = max(0, geometry.size.width - gaps)
            HStack(spacing: 2) {
                ForEach(visible) { segment in
                    RoundedRectangle(cornerRadius: height / 3, style: .continuous)
                        .fill(segment.color)
                        .frame(width: max(2, usable * CGFloat(min(1, segment.fraction))))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(trackColor, in: RoundedRectangle(cornerRadius: height / 3, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Per-core bars

/// Every core's load as a thin vertical bar, grouped by core kind. Group
/// widths are proportional to their core counts so all bars share one width.
struct CoreLoadBars: View {
    let groups: [CPUCoreGroup]
    let perCore: [Double]
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WeightedHStack(spacing: 14, weights: groups.map { Double(max(1, $0.coreIndices.count)) }) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                groupView(group)
            }
        }
    }

    private func groupView(_ group: CPUCoreGroup) -> some View {
        let loads = group.coreIndices.map { perCore.indices.contains($0) ? perCore[$0] : 0 }
        let average = loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(groups.count > 1 ? "\(group.name) · \(group.coreIndices.count)" : "\(group.coreIndices.count) cores")
                    .font(PortlyTypography.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(SystemStatsFormat.percent(average))
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                        Rectangle()
                            .fill(tint.opacity(0.35 + 0.65 * min(1, load)))
                            .scaleEffect(x: 1, y: max(0.03, min(1, load)), anchor: .bottom)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: load)
                }
            }
            .frame(height: 28)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name) cores")
        .accessibilityValue(
            "Average \(SystemStatsFormat.percent(average)); busiest \(SystemStatsFormat.percent(loads.max() ?? 0))"
        )
    }
}

/// Lays children side by side with widths proportional to `weights`.
struct WeightedHStack: Layout {
    var spacing: CGFloat
    var weights: [Double]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let widths = columnWidths(total: width, count: subviews.count)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func columnWidths(total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let usable = max(0, total - spacing * CGFloat(count - 1))
        let weights = (0..<count).map { $0 < self.weights.count ? max(0.0001, self.weights[$0]) : 1 }
        let sum = weights.reduce(0, +)
        return weights.map { usable * CGFloat($0 / sum) }
    }
}

// MARK: - Grid

/// Two columns of equal-height cards, one column when the view is narrow.
/// A lone last card spans the full width so the grid never ends on a hole.
struct SystemCardGridLayout: Layout {
    var minimumCardWidth: CGFloat = 340
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumCardWidth * 2 + spacing
        return CGSize(width: width, height: frames(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = frames(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let columns = SystemCardGridMetrics.columns(
            forWidth: width,
            minimumCardWidth: minimumCardWidth,
            spacing: spacing
        )
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        for row in SystemCardGridMetrics.rows(cardCount: subviews.count, columns: columns) {
            let cellWidth = row.count == 1
                ? width
                : (width - spacing * CGFloat(row.count - 1)) / CGFloat(row.count)
            let height = row
                .map { subviews[$0].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }
                .max() ?? 0
            for (column, index) in row.enumerated() {
                frames[index] = CGRect(
                    x: CGFloat(column) * (cellWidth + spacing),
                    y: y,
                    width: cellWidth,
                    height: height
                )
            }
            y += height + spacing
        }
        return (frames, max(0, y - spacing))
    }
}

// MARK: - Window visibility

/// Reports whether the hosting window is actually visible (not minimized,
/// hidden, on another Space or fully covered), so sampling can pause.
struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observation: NSObjectProtocol?
        private var lastReported: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                report(false)
                return
            }
            observation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.reportCurrentState()
            }
            reportCurrentState()
        }

        func stopObserving() {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
            observation = nil
        }

        private func reportCurrentState() {
            report(window?.occlusionState.contains(.visible) ?? false)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            // Never mutate SwiftUI state from inside a view update.
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(visible)
            }
        }
    }
}
