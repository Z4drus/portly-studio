import AppKit
import PortlyCore
import SwiftUI

/// The menu bar popover: everything you need without opening the window, and a
/// way in when you do.
struct MenuBarContent: View {
    @EnvironmentObject private var supervisor: Supervisor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var listHeight: CGFloat = 0

    private static let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            MenuBarUsageRows()

            if supervisor.projects.isEmpty {
                emptyState
            } else {
                // A menu bar window sizes itself to the content's fitting size, and
                // a ScrollView reports none, so it would collapse to nothing. Measure
                // the list and give the scroller an explicit height.
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(supervisor.projects) { project in
                            projectSection(project)
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ListHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                }
                .frame(height: min(max(listHeight, estimatedListHeight), Self.maxListHeight))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            }

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear {
            WindowOpener.opener = { openWindow(id: WindowOpener.mainWindowID) }
        }
    }

    /// Fallback used before the list has been measured, so the popover never
    /// opens empty: roughly one 22pt row per project header and per server.
    private var estimatedListHeight: CGFloat {
        let rows = supervisor.projects.reduce(0) { $0 + 1 + $1.servers.count }
        return CGFloat(rows) * 22 + 12
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Portly")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.state, value: supervisor.runningCount)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let running = supervisor.runningCount
        let total = supervisor.projects.reduce(0) { $0 + $1.servers.count }
        return "\(running)/\(total) running"
    }

    private func projectSection(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                NucleoIconView(LegacyProjectIcons.resolve(project.icon), size: 12)
                    .foregroundStyle(Color(hex: project.color))
                    .frame(width: 13)
                Text(project.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    supervisor.startProject(project.id)
                } label: {
                    NucleoIconView(.play, size: 10)
                }
                .buttonStyle(.borderless)
                .help("Start every server in \(project.name)")

                Button {
                    supervisor.stopProject(project.id)
                } label: {
                    NucleoIconView(.stop, size: 10)
                }
                .buttonStyle(.borderless)
                .help("Stop every server in \(project.name)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(project.servers) { server in
                if let runtime = supervisor.runtime(for: server.id) {
                    MenuBarServerRow(runtime: runtime)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No projects yet")
                .font(.system(size: 12, weight: .medium))
            Text("Open the window to add a project and its servers.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Portly") {
                WindowOpener.openMainWindow()
            }
            .buttonStyle(.borderless)

            Button("Ports") {
                AppSelection.shared.pending = .ports
                WindowOpener.openMainWindow()
            }
            .buttonStyle(.borderless)

            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    openSettings()
                }
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Stop All") {
                supervisor.stopAll()
            }
            .buttonStyle(.borderless)
            .disabled(supervisor.runningCount == 0)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct MenuBarServerRow: View {
    @ObservedObject var runtime: ServerRuntime
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: runtime.state)

            Text(runtime.config.name)
                .font(.system(size: 12))
                .lineLimit(1)

            if let port = runtime.effectivePort {
                Text(":\(String(port))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            StartStopButton(runtime: runtime, symbolSize: 9)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.secondary.opacity(0.12) : Color.clear)
                .padding(.horizontal, 6)
        )
        .animation(Motion.hover, value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            AppSelection.shared.pending = .server(runtime.id)
            WindowOpener.openMainWindow()
        }
    }
}

/// The AI usage readings in the popover: one line per assistant, so the
/// answer is there in menu-bar-only mode without opening a window.
private struct MenuBarUsageRows: View {
    @ObservedObject private var center = UsageCenter.shared
    @ObservedObject private var store: UsageStore
    @ObservedObject private var preferences: UsagePreferences
    @State private var now = Date()

    init() {
        let center = UsageCenter.shared
        _store = ObservedObject(wrappedValue: center.store)
        _preferences = ObservedObject(wrappedValue: center.preferences)
    }

    var body: some View {
        if preferences.showInMenuBar, !center.displaySnapshots.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    NucleoIconView(.sparkle, size: 11)
                        .foregroundStyle(.secondary)
                    Text("AI usage")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

                ForEach(center.displaySnapshots) { snapshot in
                    MenuBarUsageRow(
                        snapshot: snapshot,
                        activity: center.activity(for: snapshot.id),
                        isRefreshing: store.refreshing.contains(snapshot.id),
                        now: now
                    ) {
                        center.refresh(providerID: snapshot.id)
                    }
                }
            }
            .padding(.bottom, 6)
            .onAppear { now = Date() }

            Divider()
        }
    }
}

private struct MenuBarUsageRow: View {
    let snapshot: ProviderSnapshot
    let activity: ActivitySummary?
    let isRefreshing: Bool
    let now: Date
    let onRefresh: () -> Void

    @State private var hovering = false

    private var band: UsageBand { UsageBand.band(for: snapshot.usedFraction ?? 0) }

    /// The headline window's reset, or the reason there is no reading.
    private var detail: String {
        if let message = snapshot.statusMessage { return message }
        guard let headline = snapshot.headline else { return "" }
        let reset = headline.resetsAt.map { ResetCopy.text(for: $0, now: now) }
        return [headline.label, reset].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            MiniUsageRing(snapshot: snapshot, size: 15)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(snapshot.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if let activity, activity.state != .idle {
                        Text(activity.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(activity.state == .waiting ? Color.orange : Color.accentColor)
                    }
                }
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            }
            Text(snapshot.hasReading ? snapshot.headlineText : "—")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(snapshot.hasReading ? band.tint : Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.secondary.opacity(0.12) : Color.clear)
                .padding(.horizontal, 6)
        )
        .animation(Motion.hover, value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onRefresh)
        .help("Click to refresh \(snapshot.displayName)'s reading")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.displayName) \(snapshot.headlineText) used")
    }
}

/// Carries the measured height of the project list out of the ScrollView.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Lets the menu bar ask the main window to focus a specific server.
final class AppSelection: ObservableObject {
    static let shared = AppSelection()
    @Published var pending: MainView.Selection?
    private init() {}
}
