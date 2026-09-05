import SwiftUI

/// Renders a `PaneLayout` tree with draggable dividers. Leaves are supplied
/// by the caller so the layout knows nothing about terminals.
struct SplitLayoutView: View {
    let layout: PaneLayout
    let zoomedPaneID: String?
    let onRatioChange: (String, Double) -> Void
    let leaf: (TerminalPaneConfig) -> AnyView

    var body: some View {
        if let zoomedPaneID, let pane = layout.pane(zoomedPaneID) {
            leaf(pane)
        } else {
            node(layout)
        }
    }

    private func node(_ layout: PaneLayout) -> AnyView {
        switch layout {
        case .leaf(let pane):
            return leaf(pane)
        case .split(let id, let axis, let ratio, let first, let second):
            return AnyView(
                SplitNode(
                    id: id,
                    axis: axis,
                    ratio: ratio,
                    onRatioChange: onRatioChange,
                    first: node(first),
                    second: node(second)
                )
            )
        }
    }
}

/// Two children and the divider between them. The gap is the hit area; the
/// visible line inside it only lights up on hover or drag, like Xcode's.
private struct SplitNode: View {
    let id: String
    let axis: SplitAxis
    let ratio: Double
    let onRatioChange: (String, Double) -> Void
    let first: AnyView
    let second: AnyView

    @State private var dragging = false
    @State private var hovering = false

    private let gap: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let usable = max(0, total - gap)
            let firstLength = (usable * ratio).rounded()
            let secondLength = max(0, usable - firstLength)

            if axis == .horizontal {
                HStack(spacing: 0) {
                    first.frame(width: firstLength)
                    divider(total: total).frame(width: gap)
                    second.frame(width: secondLength)
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: firstLength)
                    divider(total: total).frame(height: gap)
                    second.frame(height: secondLength)
                }
            }
        }
        .coordinateSpace(name: id)
    }

    private func divider(total: CGFloat) -> some View {
        let active = dragging || hovering
        return ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(active ? Color.accentColor.opacity(dragging ? 0.9 : 0.55) : Color.clear)
                .frame(
                    width: axis == .horizontal ? 2 : nil,
                    height: axis == .vertical ? 2 : nil
                )
                .padding(axis == .horizontal ? .vertical : .horizontal, 10)
        }
        .contentShape(Rectangle())
        .animation(Motion.hover, value: active)
        .onHover { inside in
            hovering = inside
            if inside {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(id))
                .onChanged { value in
                    dragging = true
                    let position = axis == .horizontal ? value.location.x : value.location.y
                    guard total > 0 else { return }
                    onRatioChange(id, Double(position / total))
                }
                .onEnded { _ in dragging = false }
        )
        .accessibilityLabel(axis == .horizontal ? "Resize panes horizontally" : "Resize panes vertically")
    }
}
