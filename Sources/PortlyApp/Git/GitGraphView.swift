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
                    isFirst: index == 0,
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
    let isFirst: Bool
    let isLast: Bool
    let graphWidth: CGFloat

    private var commit: GitCommit { row.commit }

    var body: some View {
        HStack(spacing: 8) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: graphWidth, height: GitGraphView.rowHeight)
            .accessibilityHidden(true)

            Text(commit.subject)
                .font(PortlyTypography.body)
                .foregroundStyle(commit.isLocalOnly ? Color.primary : Color.primary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            ForEach(Array(commit.branchNames.prefix(2).enumerated()), id: \.offset) { _, name in
                refBadge(name)
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

            Text(commit.shortHash)
                .font(PortlyTypography.metadata)
                .foregroundStyle(.quaternary)
        }
        .frame(height: GitGraphView.rowHeight)
        .help("\(commit.subject)\n\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))\(commit.isLocalOnly ? "\nNot pushed yet" : "")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(commit.subject), \(commit.author), \(commit.date.formatted(date: .abbreviated, time: .shortened))\(commit.isLocalOnly ? ", not pushed" : "")")
    }

    private func refBadge(_ name: String) -> some View {
        let isRemote = name.contains("/")
        return Text(name)
            .font(PortlyTypography.label)
            .foregroundStyle(isRemote ? Color.secondary : GitGraphView.laneColor(row.color))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 110)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background {
                Capsule(style: .continuous)
                    .fill((isRemote ? Color.primary : GitGraphView.laneColor(row.color)).opacity(0.1))
            }
            .help(isRemote ? "Remote branch \(name)" : "Branch \(name)")
    }

    private func x(_ lane: Int) -> CGFloat {
        CGFloat(min(lane, GitGraphView.maxDrawnLanes - 1)) * GitGraphView.laneWidth + GitGraphView.laneWidth / 2 + 3
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let lineWidth: CGFloat = 1.5

        // Lines arriving from the row above end at this commit's lane or run past it.
        if !isFirst {
            for lane in row.passingLanes {
                var path = Path()
                path.move(to: CGPoint(x: x(lane), y: 0))
                path.addLine(to: CGPoint(x: x(lane), y: midY))
                context.stroke(path, with: .color(GitGraphView.laneColor(colorOfPassingLane(lane)).opacity(0.55)), lineWidth: lineWidth)
            }
            var into = Path()
            into.move(to: CGPoint(x: x(row.lane), y: 0))
            into.addLine(to: CGPoint(x: x(row.lane), y: midY))
            context.stroke(into, with: .color(GitGraphView.laneColor(row.color).opacity(0.75)), lineWidth: lineWidth)
        }

        // Lines leaving towards the row below: straight, or bending into
        // another lane when branches meet.
        if !isLast {
            for edge in row.edges {
                var path = Path()
                let from = CGPoint(x: x(edge.fromLane), y: midY)
                let to = CGPoint(x: x(edge.toLane), y: size.height)
                path.move(to: from)
                if edge.fromLane == edge.toLane {
                    path.addLine(to: to)
                } else {
                    path.addCurve(
                        to: to,
                        control1: CGPoint(x: from.x, y: midY + (size.height - midY) * 0.9),
                        control2: CGPoint(x: to.x, y: midY + (size.height - midY) * 0.1)
                    )
                }
                let alpha = edge.fromLane == row.lane ? 0.75 : 0.55
                context.stroke(path, with: .color(GitGraphView.laneColor(edge.color).opacity(alpha)), lineWidth: lineWidth)
            }
        }

        // The commit itself.
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
            let ring = Path(ellipseIn: CGRect(x: center.x - radius - 2.5, y: center.y - radius - 2.5, width: (radius + 2.5) * 2, height: (radius + 2.5) * 2))
            context.stroke(ring, with: .color(color.opacity(0.35)), lineWidth: 1)
        }
    }

    /// A passing lane keeps the colour of the edge that continues it.
    private func colorOfPassingLane(_ lane: Int) -> Int {
        row.edges.first { $0.fromLane == lane }?.color ?? lane
    }
}
