import AppKit
import SwiftUI

// MARK: - Small Talvo pieces shared by the button, the panel and the detail

/// A person's initials in their Talvo colour.
struct TalvoAvatar: View {
    let user: TalvoUser?
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(user.map { Color(hex: $0.color) } ?? Color.primary.opacity(0.08))
            if let user {
                Text(user.initials)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                NucleoIconView(.user, size: size * 0.55)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .help(user?.name ?? "Unassigned")
        .accessibilityLabel(user?.name ?? "Unassigned")
    }
}

/// The status of an issue as Linear draws it: a ring that fills as work
/// progresses, a check once done, a cross once dropped.
struct TalvoStatusGlyph: View {
    let status: TalvoStatus?
    var size: CGFloat = 12

    var body: some View {
        let color = status.map { Color(hex: $0.color) } ?? Color.secondary
        ZStack {
            switch status?.type {
            case .backlog?:
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [1.6, 1.6]))
                    .foregroundStyle(color)
            case .unstarted?, nil:
                Circle()
                    .strokeBorder(color, lineWidth: 1.4)
            case .started?:
                Circle()
                    .strokeBorder(color, lineWidth: 1.4)
                PieSlice(fraction: 0.5)
                    .fill(color)
                    .padding(size * 0.22)
            case .completed?:
                Circle().fill(color)
                NucleoIconView(.check, size: size * 0.6)
                    .foregroundStyle(.white)
            case .canceled?:
                Circle().fill(color.opacity(0.9))
                NucleoIconView(.xmark, size: size * 0.55)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .help(status?.name ?? "Unknown status")
        .accessibilityLabel(status?.name ?? "Unknown status")
    }

    private struct PieSlice: Shape {
        let fraction: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            path.move(to: center)
            path.addArc(
                center: center,
                radius: min(rect.width, rect.height) / 2,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * fraction),
                clockwise: false
            )
            path.closeSubpath()
            return path
        }
    }
}

/// Priority as signal bars, urgent as an exclamation badge, none as a dash.
struct TalvoPriorityGlyph: View {
    let priority: TalvoPriority
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch priority {
            case .urgent:
                Text("!")
                    .font(.system(size: size * 0.8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            case .none:
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: size * 0.6, height: 1.5)
                    .frame(width: size, height: size)
            default:
                HStack(alignment: .bottom, spacing: size * 0.12) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(index < bars ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                            .frame(width: size * 0.22, height: size * (0.4 + 0.3 * Double(index)))
                    }
                }
                .frame(width: size, height: size, alignment: .bottom)
            }
        }
        .help(priority.label)
        .accessibilityLabel(priority.label)
    }

    private var bars: Int {
        switch priority {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        default: return 0
        }
    }
}

/// A small tinted capsule: a label, a status, a health.
struct TalvoChip: View {
    let text: String
    var color: Color = .secondary
    var icon: AppIcon?

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                NucleoIconView(icon, size: 9)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(PortlyTypography.label)
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(color.opacity(0.12), in: Capsule(style: .continuous))
    }
}

/// Done over counted, as a thin bar with the figure beside it.
struct TalvoProgressBar: View {
    let progress: TalvoProgress
    var color: Color = .accentColor
    var showsFigure = true

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(proxy.size.width * progress.ratio, progress.completed > 0 ? 4 : 0))
                }
            }
            .frame(height: 4)
            if showsFigure {
                Text("\(progress.completed)/\(progress.total - progress.canceled)")
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.completed) of \(progress.total - progress.canceled) issues done")
    }
}

/// Talvo stores an icon by name alone (`rocket`); the bundled Nucleo set is
/// addressed by `category/name`. Find the glyph by name, in any category.
enum TalvoIcons {
    private static var resolved: [String: String] = [:]

    static func glyph(for name: String?, fallback: AppIcon = .projectDefault) -> String {
        guard let name, !name.isEmpty else { return fallback.rawValue }
        if let cached = resolved[name] { return cached }
        let catalog = IconCatalog.shared
        let id = catalog.contains(name)
            ? name
            : catalog.icons.first { $0.name == name }?.id ?? fallback.rawValue
        resolved[name] = id
        return id
    }
}

/// `3h`, `2d`: when something happened, for a list row.
func talvoAge(_ iso: String?) -> String {
    TalvoDates.parse(iso)?.compactAge ?? ""
}

/// Search text the way people type it: no case, no accents, hyphens kept so
/// `BLE-12` finds `BLE-12`.
enum TalvoSearch {
    static func fold(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Links written in Talvo open in the browser, and only when they are web
/// or mail links: a `file:` or custom-scheme URL in a description opens nothing.
enum TalvoLinks {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func open(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        open(url)
    }

    static func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}
