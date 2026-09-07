import Foundation

/// Which screen edge the notch is welded to.
///
/// The edge decides two things that ripple through the whole surface: which
/// way the provider stack runs, and which way the tooltip leaves. A side edge
/// keeps the vertical column; top and bottom turn the stack on its side.
enum NotchEdge: String, CaseIterable, Identifiable {
    case right
    case left
    case top
    case bottom

    var id: String { rawValue }

    /// True when the stack runs down the screen rather than across it.
    var isVertical: Bool { self == .right || self == .left }

    /// Where the tooltip goes: away from the bezel, always.
    enum TooltipDirection: Equatable {
        case leading    // card to the left of the notch
        case trailing   // card to the right of it
        case up         // card above it
        case down       // card below it
    }

    var tooltipDirection: TooltipDirection {
        switch self {
        case .right: return .leading
        case .left: return .trailing
        case .top: return .down
        case .bottom: return .up
        }
    }

    /// A unit vector pointing at the bezel, in panel coordinates (y grows
    /// down, as in a flipped `NSHostingView` and in SwiftUI).
    var outward: CGPoint {
        switch self {
        case .right: return CGPoint(x: 1, y: 0)
        case .left: return CGPoint(x: -1, y: 0)
        case .top: return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        }
    }

    /// A unit vector along the stack, perpendicular to `outward`.
    var alongDirection: CGPoint {
        isVertical ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
    }

    var title: String {
        switch self {
        case .right: return "Right"
        case .left: return "Left"
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }

    var explanation: String {
        switch self {
        case .right:
            return "Down the right-hand edge, clear of a Dock on that side."
        case .left:
            return "Down the left-hand edge, clear of a Dock on that side."
        case .top:
            return "A wide bar across the top, readings side by side. On a Mac "
                + "with a notch of its own it runs up to meet it, so the two "
                + "read as one shape."
        case .bottom:
            return "A wide bar resting on top of the Dock, readings side by side."
        }
    }
}

/// The one place in the notch that knows which way round the axes are.
///
/// Everything else works in **stack space**: `along` runs the length of the
/// provider stack, and `across` measures inward from the bezel, so zero is
/// always the screen edge. This type turns a stack-space coordinate into a
/// point in the panel, whose origin is top-left.
struct NotchPlacement {
    let edge: NotchEdge
    let panelSize: CGSize

    func point(along: CGFloat, across: CGFloat) -> CGPoint {
        switch edge {
        case .right: return CGPoint(x: panelSize.width - across, y: along)
        case .left: return CGPoint(x: across, y: along)
        case .top: return CGPoint(x: along, y: across)
        case .bottom: return CGPoint(x: along, y: panelSize.height - across)
        }
    }

    /// A rect spanning `depth` **inward** from `across`, so a hit region
    /// anchored at the bezel never hangs off the far side of it.
    func rect(along: CGFloat, across: CGFloat, length: CGFloat, depth: CGFloat) -> CGRect {
        switch edge {
        case .right:
            return CGRect(x: panelSize.width - across - depth, y: along,
                          width: depth, height: length)
        case .left:
            return CGRect(x: across, y: along, width: depth, height: length)
        case .top:
            return CGRect(x: along, y: across, width: length, height: depth)
        case .bottom:
            return CGRect(x: along, y: panelSize.height - across - depth,
                          width: length, height: depth)
        }
    }

    /// The panel needed for a stack of `length` and a depth of `depth`.
    static func panelSize(edge: NotchEdge, length: CGFloat, depth: CGFloat) -> CGSize {
        edge.isVertical
            ? CGSize(width: depth, height: length)
            : CGSize(width: length, height: depth)
    }

    /// The inverse: how far along the stack a point in the panel is.
    func along(of point: CGPoint) -> CGFloat {
        edge.isVertical ? point.y : point.x
    }

    /// And how far in from the bezel.
    func across(of point: CGPoint) -> CGFloat {
        switch edge {
        case .right: return panelSize.width - point.x
        case .left: return point.x
        case .top: return point.y
        case .bottom: return panelSize.height - point.y
        }
    }
}

/// The display's *own* notch — the camera housing on a MacBook, not ours.
struct HardwareNotch: Equatable {
    let width: CGFloat
    let height: CGFloat
}

/// Everything the geometry maths needs from a screen, so it can be faked in tests.
protocol ScreenDescribing {
    var frameValue: CGRect { get }
    var visibleFrameValue: CGRect { get }
    var hardwareNotch: HardwareNotch? { get }
}

extension ScreenDescribing {
    var hardwareNotch: HardwareNotch? { nil }
}
