import SwiftUI

/// Which mark a provider cell draws.
enum ProviderGlyph: String, Codable, Equatable {
    case claude
    case openai
    case cursor
    case grok

    /// How much to scale this mark so it reads the same size as the others.
    /// Boxes of equal size are not marks of equal size, and the eye reads the
    /// mark; each value brings that glyph's ink to the same extent as Claude's.
    var opticalScale: CGFloat {
        switch self {
        case .claude: return 0.97
        case .cursor: return 0.97
        case .openai: return 0.94
        case .grok: return 1.0
        }
    }

    var outline: [[CGPoint]] {
        switch self {
        case .claude: return GlyphOutline.claude
        case .openai: return GlyphOutline.openai
        case .cursor: return GlyphOutline.cursor
        case .grok: return GlyphOutline.grok
        }
    }
}

/// A traced outline scaled into the view's bounds, filled even-odd so the
/// counters inside a knot stay open.
struct GlyphShape: Shape {
    let outline: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for loop in outline {
            guard let first = loop.first else { continue }
            path.move(to: point(first, in: rect))
            for p in loop.dropFirst() { path.addLine(to: point(p, in: rect)) }
            path.closeSubpath()
        }
        return path
    }

    private func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
}

/// A provider mark, tinted by the current foreground style.
struct ProviderGlyphView: View {
    let glyph: ProviderGlyph
    var size: CGFloat = NotchDesign.px(46)

    var body: some View {
        GlyphShape(outline: glyph.outline)
            .fill(style: FillStyle(eoFill: true))
            // Scaled inside a frame of the fixed size, so the layout stays on a
            // single grid while the ink is evened out within it.
            .scaleEffect(glyph.opticalScale)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
