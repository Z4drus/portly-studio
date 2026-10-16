import SwiftUI

/// What a new agent terminal shows instead of its shell prompt and the
/// command being typed into it: the terminal's own black, the agent's
/// mascot, a small pixel loader and a line saying whether the chat is new or
/// resumed. It sits there for the second or two Claude Code takes to draw its
/// first screen, then lifts.
///
/// No elapsed time, no percentage, no folder: nothing here is waiting on an
/// answer, and the pane header already says where the agent runs.
struct AgentLaunchOverlay: View {
    let agentName: String
    /// The agent's glyph, for agents without a mascot of their own.
    let iconID: String
    let resumes: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cover is there from the first frame, so nothing animates in; it
    /// fades out and opens slightly, the terminal appearing underneath.
    static let transition = AnyTransition.asymmetric(
        insertion: .identity,
        removal: .opacity.combined(with: .scale(scale: 1.015))
    )
    static let lift = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)

    private var isClaude: Bool { agentName.lowercased().contains("claude") }

    private var headline: String {
        resumes ? "Resuming the conversation" : "Starting \(agentName)"
    }

    var body: some View {
        ZStack {
            Color(nsColor: TerminalTheme.background)
            VStack(spacing: 22) {
                if isClaude {
                    ClaudeMascot(width: 62, animated: !reduceMotion)
                } else {
                    NucleoIconView(iconID, size: 26)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 52, height: 52)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                }
                HStack(spacing: 9) {
                    PixelGridLoader(animated: !reduceMotion)
                    ShimmerLabel(headline, animated: !reduceMotion)
                }
            }
            .padding(24)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headline)
    }
}

/// Claude Code's mascot, the way its terminal draws it: an orange block with
/// two dark eyes, two stubby arms and four legs. Drawn from rectangles so it
/// scales crisply at any size; it blinks now and then, nothing more.
struct ClaudeMascot: View {
    let width: CGFloat
    var animated = true

    @State private var blinking = false

    /// Claude's orange, as it reads on the terminal's black.
    static let orange = Color(.sRGB, red: 0.86, green: 0.47, blue: 0.34, opacity: 1)

    /// The figure in a 615 × 345 space: the body, then arms and legs hanging
    /// off it, then the eyes cut out of it.
    private static let body: [CGRect] = [
        CGRect(x: 70, y: 0, width: 475, height: 280),
        CGRect(x: 0, y: 145, width: 70, height: 65),
        CGRect(x: 545, y: 145, width: 70, height: 65),
        CGRect(x: 70, y: 280, width: 40, height: 65),
        CGRect(x: 145, y: 280, width: 35, height: 65),
        CGRect(x: 435, y: 280, width: 40, height: 65),
        CGRect(x: 505, y: 280, width: 40, height: 65),
    ]
    private static let eyes: [CGRect] = [
        CGRect(x: 140, y: 70, width: 40, height: 70),
        CGRect(x: 435, y: 70, width: 40, height: 70),
    ]
    private static let space = CGSize(width: 615, height: 345)

    /// Blinks come every few seconds and last a tenth of one.
    private static let blinkClock = Timer.publish(every: 3.4, on: .main, in: .common).autoconnect()

    var body: some View {
        let scale = width / Self.space.width
        let height = Self.space.height * scale
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.body.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Self.orange)
                    .frame(width: rect.width * scale, height: rect.height * scale)
                    .offset(x: rect.minX * scale, y: rect.minY * scale)
            }
            ForEach(Array(Self.eyes.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color(nsColor: TerminalTheme.background))
                    .frame(width: rect.width * scale, height: rect.height * scale)
                    .scaleEffect(y: blinking ? 0.12 : 1, anchor: .center)
                    .offset(x: rect.minX * scale, y: rect.minY * scale)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.09), value: blinking)
        .onReceive(Self.blinkClock) { _ in
            guard animated else { return }
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { blinking = false }
        }
        .accessibilityHidden(true)
    }
}

/// A 3 × 3 grid of pixels with a chevron-shaped wave driving across it. The
/// cycle is shorter than the sweep, so two fronts are always in flight. It
/// is the size of a lowercase letter next to the label, not a badge.
struct PixelGridLoader: View {
    var animated = true
    var cell: CGFloat = 2.5
    var gap: CGFloat = 1.25
    var tint: Color = Color(nsColor: TerminalTheme.foreground)

    private static let cycle: Double = 0.65
    private static let step: Double = 0.09
    private static let dim = 0.15

    /// Per cell, how far behind the wavefront it lights: column plus distance
    /// from the middle row, so the front reads as a chevron pointing right.
    private static let delays: [Double] = (0..<9).map { index in
        let row = index / 3, column = index % 3
        return Double(column + abs(row - 1)) * step
    }

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    grid(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                grid(at: nil)
            }
        }
        .accessibilityHidden(true)
    }

    private func grid(at time: TimeInterval?) -> some View {
        let side = cell * 3 + gap * 2
        return ZStack(alignment: .topLeading) {
            ForEach(0..<9, id: \.self) { index in
                let row = index / 3, column = index % 3
                RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                    .fill(tint)
                    .opacity(opacity(index: index, time: time))
                    .frame(width: cell, height: cell)
                    .offset(x: CGFloat(column) * (cell + gap), y: CGFloat(row) * (cell + gap))
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }

    private func opacity(index: Int, time: TimeInterval?) -> Double {
        guard let time else { return Self.dim }
        let phase = (time - Self.delays[index]).truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
        let wrapped = phase < 0 ? phase + 1 : phase
        // A smooth bump: off, on, off, with the ease of a sine.
        let on = sin(wrapped * .pi)
        return Self.dim + (1 - Self.dim) * on
    }
}

/// A label with a highlight sweeping through it, the way a loading title
/// shimmers: the words stay still, the light moves.
struct ShimmerLabel: View {
    let text: String
    var animated = true

    private static let period: Double = 1.4
    private static let base = Color(nsColor: TerminalTheme.foreground).opacity(0.5)
    private static let bright = Color(nsColor: TerminalTheme.foreground)

    init(_ text: String, animated: Bool = true) {
        self.text = text
        self.animated = animated
    }

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.period) / Self.period
                    label.foregroundStyle(gradient(phase: phase))
                }
            } else {
                label.foregroundStyle(Self.base)
            }
        }
    }

    private var label: some View {
        Text(text)
            .font(PortlyTypography.bodyMedium)
            .lineLimit(1)
    }

    private func gradient(phase: Double) -> LinearGradient {
        // One gradient width wide, swept from left of the text to right of it.
        let start = -1 + 2 * phase
        return LinearGradient(
            stops: [
                .init(color: Self.base, location: 0),
                .init(color: Self.base, location: 0.35),
                .init(color: Self.bright, location: 0.5),
                .init(color: Self.base, location: 0.65),
                .init(color: Self.base, location: 1),
            ],
            startPoint: UnitPoint(x: start, y: 0.5),
            endPoint: UnitPoint(x: start + 1, y: 0.5)
        )
    }
}
