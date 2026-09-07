import AppKit
import SwiftUI

/// The AI usage readout at the foot of the sidebar, just above Resources.
///
/// Collapsed it is one row: a mini ring per tracked assistant, so "which one
/// still has room" is answered without opening anything. Opened, each
/// assistant lists its limit windows with a bar and its reset time — the same
/// facts the notch's tooltip shows, on Portly's own surface.
struct UsageSidebarSection: View {
    @ObservedObject private var center = UsageCenter.shared
    @ObservedObject private var store: UsageStore
    @ObservedObject private var preferences: UsagePreferences
    @AppStorage("usage.sidebarExpanded") private var expanded = false
    @State private var now = Date()

    /// Keeps "Resets in N min" honest while the section sits open.
    private static let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init() {
        let center = UsageCenter.shared
        _store = ObservedObject(wrappedValue: center.store)
        _preferences = ObservedObject(wrappedValue: center.preferences)
    }

    var body: some View {
        if preferences.showInSidebar, !center.displaySnapshots.isEmpty {
            VStack(spacing: 0) {
                header
                if expanded {
                    VStack(spacing: 10) {
                        ForEach(center.displaySnapshots) { snapshot in
                            ProviderUsageRow(
                                snapshot: snapshot,
                                activity: center.activity(for: snapshot.id),
                                isRefreshing: store.refreshing.contains(snapshot.id),
                                now: now
                            ) {
                                center.refresh(providerID: snapshot.id)
                            }
                        }
                        footer
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(Motion.state, value: expanded)
            .animation(Motion.state, value: center.displaySnapshots.map(\.id))
            .onReceive(Self.clock) { now = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("AI usage")
        }
    }

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 8) {
                NucleoIconView(.sparkle, size: 14)
                Text("AI usage")
                Spacer(minLength: 6)
                if !expanded {
                    HStack(spacing: 5) {
                        ForEach(center.displaySnapshots) { snapshot in
                            MiniUsageRing(snapshot: snapshot, size: 15)
                                .help(compactHelp(snapshot))
                        }
                    }
                    .transition(.opacity)
                }
                NucleoIconView(.chevronDown, size: 9)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .accessibilityLabel(expanded ? "Hide AI usage" : "Show AI usage")
        .accessibilityHint("Usage limits of the AI assistants you track")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(store.lastRefreshedAt.map { "Updated \(ElapsedCopy.ago(since: $0, now: now))" } ?? "Waiting for the first reading…")
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                store.refreshNow()
            } label: {
                NucleoIconView(.restart, size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.refreshing.isEmpty)
            .help("Refresh every reading now")
            .accessibilityLabel("Refresh usage")
        }
    }

    private func compactHelp(_ snapshot: ProviderSnapshot) -> String {
        guard let headline = snapshot.headline, snapshot.hasReading else {
            return "\(snapshot.displayName): \(snapshot.statusMessage ?? "no reading")"
        }
        let reset = headline.resetsAt.map { " · \(ResetCopy.text(for: $0, now: now))" } ?? ""
        return "\(snapshot.displayName) · \(headline.label) \(snapshot.headlineText) used\(reset)"
    }
}

/// A ring small enough for the collapsed header: track plus arc, no glyph.
struct MiniUsageRing: View {
    let snapshot: ProviderSnapshot
    var size: CGFloat = 15

    private var fraction: CGFloat {
        CGFloat(min(max(snapshot.usedFraction ?? 0, 0), 1))
    }

    private var band: UsageBand { UsageBand.band(for: snapshot.usedFraction ?? 0) }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 2.5)
            if snapshot.hasReading, snapshot.usedFraction != nil {
                Circle()
                    .inset(by: 1.25)
                    .trim(from: 0, to: fraction)
                    .stroke(band.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(NotchMotion.reading, value: fraction)
            }
            ProviderGlyphView(glyph: snapshot.glyph, size: size * 0.42)
                .foregroundStyle(snapshot.hasReading ? Color.primary : Color.secondary)
        }
        .frame(width: size, height: size)
        .opacity(snapshot.status.isStale || !snapshot.hasReading ? 0.55 : 1)
        .accessibilityLabel("\(snapshot.displayName) \(snapshot.headlineText) used")
    }
}

/// One assistant: its name and headline reading, then every limit window it
/// exposes as a bar with its reset time. Clicking refetches it.
private struct ProviderUsageRow: View {
    let snapshot: ProviderSnapshot
    let activity: ActivitySummary?
    let isRefreshing: Bool
    let now: Date
    let onRefresh: () -> Void

    @State private var hovering = false

    private var headlineBand: UsageBand { UsageBand.band(for: snapshot.usedFraction ?? 0) }

    var body: some View {
        Button(action: onRefresh) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    ProviderGlyphView(glyph: snapshot.glyph, size: 12)
                        .foregroundStyle(.primary)
                        .frame(width: 14)
                    Text(snapshot.displayName)
                        .font(PortlyTypography.bodyMedium)
                        .lineLimit(1)
                    if let activity, activity.state != .idle {
                        SidebarActivityDot(summary: activity)
                    }
                    Spacer(minLength: 4)
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                            .transition(.opacity)
                    }
                    Text(snapshot.hasReading ? snapshot.headlineText : "—")
                        .font(PortlyTypography.metric)
                        .monospacedDigit()
                        .foregroundStyle(snapshot.hasReading ? headlineBand.tint : Color.secondary)
                        .contentTransition(.numericText())
                        .animation(NotchMotion.reading, value: snapshot.headlineText)
                }

                if let message = snapshot.statusMessage {
                    Text(message)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(snapshot.status == .needsAuth || snapshot.status == .accessDenied ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(snapshot.windows) { window in
                            LimitWindowBar(window: window, fidelity: snapshot.fidelity, now: now)
                        }
                    }
                }

                if let activity, !activity.sessions.isEmpty {
                    Text(sessionLine(activity))
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0.035))
            }
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(snapshot.status.isStale && snapshot.hasReading ? 0.7 : 1)
        }
        .buttonStyle(PressableRowStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.state, value: isRefreshing)
        .help(helpText)
        .accessibilityLabel("\(snapshot.displayName) usage, \(snapshot.headlineText) used")
        .accessibilityHint("Refreshes this reading")
        .contextMenu {
            Button("Refresh \(snapshot.displayName)", action: onRefresh)
            if let url = manageURL {
                Button("Open usage page") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("AI Usage Settings…") { UsageCenter.shared.openSettings() }
        }
    }

    private var manageURL: URL? {
        UsageCenter.shared.store.providers.first { $0.id == snapshot.id }?.usageURL
    }

    private var helpText: String {
        if let since = snapshot.status.staleSince, since != .distantPast, snapshot.hasReading {
            return "Last reading \(ElapsedCopy.ago(since: since, now: now)). Click to refresh."
        }
        return "Click to refresh \(snapshot.displayName)'s reading"
    }

    private func sessionLine(_ activity: ActivitySummary) -> String {
        let count = activity.sessions.count
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        if let waiting = activity.waitingSessions.first {
            return "\(sessions) · \(waiting.name) is waiting for you"
        }
        if activity.state == .working, let busy = activity.sessions.first(where: { $0.state == .busy }) {
            return "\(sessions) · \(busy.name) is working"
        }
        return "\(sessions) · idle"
    }
}

/// One limit window: label and reset on a line, then a 4pt bar.
private struct LimitWindowBar: View {
    let window: LimitWindow
    let fidelity: Fidelity
    let now: Date

    private var band: UsageBand { UsageBand.band(for: window.usedFraction ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(trailing)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(PortlyTypography.metadata)
            .foregroundStyle(.secondary)

            if let usedFraction = window.usedFraction {
                GeometryReader { proxy in
                    let fraction = CGFloat(min(max(usedFraction, 0), 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(band.tint)
                            .frame(width: max(4, proxy.size.width * fraction))
                            .animation(NotchMotion.reading, value: fraction)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label): \(window.summary)")
    }

    /// "42% · resets in 51 min": the number first, since the bar already
    /// shows the shape of it.
    private var trailing: String {
        var parts: [String] = []
        if let usedFraction = window.usedFraction {
            parts.append("\(fidelity.qualifier)\(Int((usedFraction * 100).rounded()))%")
        } else if let remaining = window.remaining {
            parts.append("\(remaining) left")
        }
        if let resetsAt = window.resetsAt {
            parts.append(ResetCopy.text(for: resetsAt, now: now).replacingOccurrences(of: "Resets", with: "resets"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A tiny turning arc while a session works, a still amber dot when one is
/// waiting on you.
private struct SidebarActivityDot: View {
    let summary: ActivitySummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch summary.state {
            case .working:
                if reduceMotion {
                    arc.rotationEffect(.degrees(-90))
                } else {
                    TimelineView(.animation) { context in
                        arc.rotationEffect(.degrees(angle(at: context.date)))
                    }
                }
            case .waiting:
                Circle().fill(Color.orange)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityLabel(summary.state == .waiting ? "A session is waiting for you" : "A session is working")
    }

    private var arc: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }

    private func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / 1.4
        return turns.truncatingRemainder(dividingBy: 1) * 360
    }
}

/// The whole row is the button: a slight press so the click is felt, nothing
/// so small it reads as exaggerated.
private struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}
