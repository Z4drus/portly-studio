import SwiftUI

/// Recent history as a lane graph: a dot per commit, lines to its parents,
/// a lane per branch. Filled dots are on a remote; hollow ones are still only
/// here. Drawn with one `Canvas` per row so the list can scroll lazily.
struct GitGraphView: View {
    let layout: GitGraph.Layout

    static let rowHeight: CGFloat = 26
    static let laneWidth: CGFloat = 12
    static let maxDrawnLanes = 5

    private var graphWidth: CGFloat {
        CGFloat(min(max(layout.laneCount, 1), Self.maxDrawnLanes)) * Self.laneWidth + 6
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(layout.rows.enumerated()), id: \.element.commit.id) { index, row in
                GitGraphRowView(
                    row: row,
                    previous: index > 0 ? layout.rows[index - 1] : nil,
                    isLast: index == layout.rows.count - 1,
                    graphWidth: graphWidth
                )
            }
        }
    }

    /// Six muted lane colours, the first being the accent so the current
    /// branch reads as "ours".
    static func laneColor(_ index: Int) -> Color {
        let palette: [Color] = [
            .accentColor,
            Color(red: 0.86, green: 0.47, blue: 0.34),
            Color(red: 0.36, green: 0.66, blue: 0.48),
            Color(red: 0.62, green: 0.50, blue: 0.86),
            Color(red: 0.90, green: 0.68, blue: 0.30),
            Color(red: 0.40, green: 0.70, blue: 0.80),
        ]
        return palette[index % palette.count]
    }
}

private struct GitGraphRowView: View {
    let row: GitGraph.Row
    /// The row above: its lines end at this row's top edge, and this row
    /// carries each one on to where it goes.
    let previous: GitGraph.Row?
    let isLast: Bool
    let graphWidth: CGFloat

    /// Even widths on whole-point centres: crisp on any screen.
    private static let lineWidth: CGFloat = 2
    private static let lineOpacity = 0.8
    private static let maxBadges = 2

    private var commit: GitCommit { row.commit }

    var body: some View {
        let badges = commit.refBadges
        HStack(spacing: 8) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: graphWidth, height: GitGraphView.rowHeight)
            .accessibilityHidden(true)

            // The subject is the only part that gives way: badges, age and
            // hash keep their size, so a row never overflows and shifts.
            Text(commit.subject)
                .font(PortlyTypography.body)
                .foregroundStyle(commit.isLocalOnly ? Color.primary : Color.primary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if !badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(badges.prefix(Self.maxBadges), id: \.self) { refBadge($0) }
                    if badges.count > Self.maxBadges {
                        Text("+\(badges.count - Self.maxBadges)")
                            .font(PortlyTypography.label)
                            .foregroundStyle(.tertiary)
                            .help(badges.dropFirst(Self.maxBadges).map(\.name).joined(separator: ", "))
                    }
                }
                .fixedSize()
            }

            Spacer(minLength: 6)

            if commit.isLocalOnly {
                NucleoIconView(.arrowUp, size: 9)
                    .foregroundStyle(Color.accentColor)
                    .help("Committed here, not pushed yet")
                    .accessibilityLabel("Not pushed")
            }

            Text(commit.date.compactAge)
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(minWidth: 26, alignment: .trailing)
                .fixedSize()

            Text(commit.shortHash)
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
                .fixedSize()
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: GitGraphView.rowHeight)
        .help("\(commit.subject)\n\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))\(commit.isLocalOnly ? "\nNot pushed yet" : "")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(commit.subject), \(commit.author), \(commit.date.formatted(date: .abbreviated, time: .shortened))\(commit.isLocalOnly ? ", not pushed" : "")")
    }

    /// Branches in their lane's colour, remote branches in grey, tags outlined.
    private func refBadge(_ ref: GitRef) -> some View {
        let lane = GitGraphView.laneColor(row.color)
        let tint: Color = ref.kind == .branch ? lane : .secondary
        return Text(ref.name)
            .font(PortlyTypography.label)
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 120)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background {
                switch ref.kind {
                case .branch:
                    Capsule(style: .continuous).fill(lane.opacity(0.14))
                case .remote:
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.08))
                case .tag:
                    Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.2))
                }
            }
            .help(Self.badgeHelp(ref))
    }

    private static func badgeHelp(_ ref: GitRef) -> String {
        switch ref.kind {
        case .branch: return "Branch \(ref.name)"
        case .remote: return "Remote branch \(ref.name), as of the last fetch"
        case .tag: return "Tag \(ref.name)"
        }
    }

    private func x(_ lane: Int) -> CGFloat {
        CGFloat(min(lane, GitGraphView.maxDrawnLanes - 1)) * GitGraphView.laneWidth + GitGraphView.laneWidth / 2 + 3
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let midY = (size.height / 2).rounded()

        // Every line in one layer, faded as a whole: where lines meet nothing
        // darkens, and a lane keeps one shade from row to row.
        var lines = context
        lines.opacity = Self.lineOpacity
        lines.drawLayer { layer in
            // The top half carries on each line the row above ended with.
            // Lines in the commit's own colour go last, so they win where
            // several meet at the dot.
            if let previous {
                let arriving = previous.edges.filter { $0.color != row.color }
                    + previous.edges.filter { $0.color == row.color }
                for edge in arriving {
                    var path = Path()
                    path.move(to: CGPoint(x: x(edge.toLane), y: 0))
                    path.addLine(to: CGPoint(x: x(edge.toLane), y: midY))
                    layer.stroke(path, with: .color(GitGraphView.laneColor(edge.color)), lineWidth: Self.lineWidth)
                }
            }

            // The bottom half: straight down, or bending into another lane
            // when branches fork or meet.
            guard !isLast else { return }
            for edge in row.edges {
                var path = Path()
                let from = CGPoint(x: x(edge.fromLane), y: midY)
                let to = CGPoint(x: x(edge.toLane), y: size.height)
                path.move(to: from)
                if edge.fromLane == edge.toLane {
                    path.addLine(to: to)
                } else {
                    let span = size.height - midY
                    path.addCurve(
                        to: to,
                        control1: CGPoint(x: from.x, y: midY + span * 0.6),
                        control2: CGPoint(x: to.x, y: midY + span * 0.4)
                    )
                }
                layer.stroke(path, with: .color(GitGraphView.laneColor(edge.color)), lineWidth: Self.lineWidth)
            }
        }

        // The commit itself, over its lines.
        let center = CGPoint(x: x(row.lane), y: midY)
        let color = GitGraphView.laneColor(row.color)
        let radius: CGFloat = commit.isHead ? 4.5 : 3.5
        let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if commit.isLocalOnly {
            context.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(dot, with: .color(Color.accentColor), lineWidth: 1.5)
        } else {
            context.fill(dot, with: .color(color))
        }
        if commit.isHead {
            let ringRadius = radius + 2.5
            let ring = Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            context.stroke(ring, with: .color(color.opacity(0.35)), lineWidth: 1)
        }
    }
}
