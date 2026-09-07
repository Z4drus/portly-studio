import AppKit
import Combine
import SwiftUI

/// Owns everything about AI usage: the providers being read, the store that
/// polls them, the notch on the screen edge, and the Claude Code session
/// monitors that make the rings spin. One per app, started from the delegate.
@MainActor
final class UsageCenter: ObservableObject {
    static let shared = UsageCenter()

    let preferences: UsagePreferences
    let store: UsageStore
    let notch = NotchWindowController()

    /// Live Claude Code sessions per provider id, mirrored from the monitors
    /// so the sidebar can show them without reaching into the notch.
    @Published private(set) var sessions: [String: [AgentSession]] = [:]

    /// The store's readings shaped by the display preferences: what the notch,
    /// the sidebar and the menu bar actually draw.
    @Published private(set) var displaySnapshots: [ProviderSnapshot] = []

    /// Every Claude Code configuration directory on this Mac, found once at
    /// launch. Each gets a usage provider and a session monitor of its own.
    let claudeProfiles: [ClaudeProfile]
    private let allProviderIDs: Set<String>
    private var monitors: [String: ClaudeSessionMonitor] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {
        let profiles = ClaudeProfile.discover()
        claudeProfiles = profiles
        // Claude Code is on by default; Codex, Cursor and Grok wait to be
        // asked for, so a credential is never read for a tool you never
        // chose to track.
        let preferences = UsagePreferences(defaultEnabled: Set(profiles.map(\.id)))
        self.preferences = preferences

        let providers: [UsageProvider] = profiles.map { ClaudeUsageProvider(profile: $0) }
            + [CodexUsageProvider(), CursorUsageProvider(), GrokUsageProvider()]
        allProviderIDs = Set(providers.map(\.id))
        store = UsageStore(
            providers: providers,
            disconnected: allProviderIDs.subtracting(preferences.enabledProviders)
        )
        displaySnapshots = Self.shape(store.snapshots, for: preferences)
    }

    /// Pure, so the shaping can be tested without a singleton.
    static func shape(_ snapshots: [ProviderSnapshot], for preferences: UsagePreferences) -> [ProviderSnapshot] {
        snapshots.map {
            $0.shaped(headline: preferences.headline, showPerModelWindows: preferences.showPerModelWindows)
        }
    }

    private func reshape() {
        let shaped = Self.shape(store.snapshots, for: preferences)
        guard shaped != displaySnapshots else { return }
        displaySnapshots = shaped
        withAnimation(NotchMotion.unfold) { notch.model.snapshots = shaped }
        notch.model.now = Date()
    }

    private func republishSessions() {
        let shown = preferences.showSessions ? sessions : [:]
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            notch.model.sessions = shown
        }
        notch.model.now = Date()
    }

    func start() {
        guard !started else { return }
        started = true
        UsageLog.usage.info("claude profiles: \(self.claudeProfiles.map(\.displayPath).joined(separator: ", "), privacy: .public)")

        // The stored edge goes in before the panel is ever put up, so a launch
        // on any other edge never flashes the right-hand one first.
        notch.model.edge = preferences.notchEdge

        preferences.$enabledProviders
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.store.disconnected = self.allProviderIDs.subtracting(enabled)
            }
            .store(in: &cancellables)

        preferences.$notchVisibility
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.notch.apply($0) }
            .store(in: &cancellables)

        preferences.$notchEdge
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.notch.apply(edge: $0) }
            .store(in: &cancellables)

        // Shaped once from three inputs rather than piped straight through:
        // the notch must never draw a window the user has switched off.
        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reshape() }
            .store(in: &cancellables)
        preferences.$headline
            .combineLatest(preferences.$showPerModelWindows)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.reshape() }
            .store(in: &cancellables)

        store.$refreshing
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in self?.notch.model.refreshing = ids }
            .store(in: &cancellables)

        for profile in claudeProfiles {
            let monitor = ClaudeSessionMonitor(directory: profile.sessionsDirectory)
            monitor.$sessions
                .receive(on: RunLoop.main)
                .sink { [weak self] live in
                    guard let self else { return }
                    self.sessions[profile.id] = live
                    self.republishSessions()
                }
                .store(in: &cancellables)
            monitors[profile.id] = monitor
            monitor.start()
        }
        preferences.$showSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.republishSessions() }
            .store(in: &cancellables)

        // Poll usage hard only while something is actually running: a Claude
        // Code session anywhere on the Mac, or an agent in a Portly terminal.
        store.isBusy = { [weak self] in
            guard let self else { return false }
            let claudeBusy = self.monitors.values.contains { monitor in
                monitor.sessions.contains { $0.state == .busy }
            }
            return claudeBusy || StudioWorkspace.shared.workingPaneCount() > 0
        }

        notch.onRefresh = { [weak self] in self?.store.refreshNow() }
        notch.onRefreshProvider = { [weak self] id in self?.refresh(providerID: id) }
        notch.onOpenSettings = { [weak self] in self?.openSettings() }
        notch.onOpenPortly = { WindowOpener.openMainWindow() }
        notch.onHide = { [weak self] in self?.preferences.notchVisibility = .hidden }

        store.start()
        notch.show()
        notch.apply(preferences.notchVisibility)
    }

    func stop() {
        guard started else { return }
        store.stop()
        monitors.values.forEach { $0.stop() }
        notch.stop()
    }

    /// A provider with no session source gets none, rather than borrowing
    /// somebody else's; nothing at all once sessions are switched off.
    func activity(for providerID: String) -> ActivitySummary? {
        guard preferences.showSessions else { return nil }
        return ActivitySummary(sessions: sessions[providerID] ?? [])
    }

    /// Refetch one provider. For a Claude ring refused by macOS this is also
    /// the way to raise the keychain prompt again.
    func refresh(providerID: String) {
        if store.refusedAccess.contains(providerID) {
            store.reauthorize(providerID: providerID)
        } else {
            store.refresh(providerID: providerID)
        }
    }

    /// Switching a provider off stops the next read and forgets what was
    /// read: its numbers must not come back at the next launch.
    func setEnabled(_ enabled: Bool, for providerID: String) {
        if !enabled { store.forget(providerID: providerID) }
        preferences.setEnabled(enabled, for: providerID)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
