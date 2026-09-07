import AppKit
import Combine

/// Fetches every enabled provider on a timer and keeps the last good answer
/// around, so a dropped network shows yesterday's number dimmed rather than a
/// blank ring.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    /// Providers with a fetch in flight, so a cell can show it happening.
    @Published private(set) var refreshing: Set<String> = []
    /// Providers whose last fetch was refused by macOS, cleared as soon as one
    /// succeeds. The settings row's only honest basis for offering to ask again.
    @Published private(set) var refusedAccess: Set<String> = []
    /// When the last full refresh finished, for the sidebar's footer.
    @Published private(set) var lastRefreshedAt: Date?

    let providers: [UsageProvider]
    /// A response belongs to the connection that started it. Checking only
    /// `disconnected` would accept an old response after a quick off/on toggle.
    private var connectionVersions: [String: UUID] = [:]
    /// Providers the user has switched off. They are not fetched at all: their
    /// credential is never read, which is the whole point of switching one off.
    @Published var disconnected: Set<String> = [] {
        didSet {
            guard disconnected != oldValue else { return }
            for id in disconnected.symmetricDifference(oldValue) {
                connectionVersions[id] = UUID()
            }
            snapshots.removeAll { disconnected.contains($0.id) }
            refusedAccess.subtract(disconnected)
            for id in disconnected { lastGood.removeValue(forKey: id) }
            archive.save(lastGood)
            for provider in providers where !disconnected.contains(provider.id)
                && !snapshots.contains(where: { $0.id == provider.id }) {
                snapshots.append(Self.placeholder(provider))
            }
            snapshots = ordered(snapshots)
            refreshNow()
        }
    }

    /// Whether any provider is actively being used right now. Usage cannot
    /// move while nothing is running, so polling hard through a quiet
    /// afternoon spends rate-limit budget to re-read an unchanged number.
    var isBusy: () -> Bool = { false }

    private let refreshInterval: TimeInterval
    /// How long a snapshot stays believable after its last successful fetch.
    /// Comfortably above `idleRefreshInterval`, so a ring never dims merely
    /// because the idle schedule has not come round yet.
    private let staleAfter: TimeInterval
    /// How often to look when nothing is running.
    private let idleRefreshInterval: TimeInterval
    private var lastAttempt: Date?

    private let archive: UsageArchive
    private var lastGood: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] = [:]
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var wakeObserver: NSObjectProtocol?

    init(
        providers: [UsageProvider],
        refreshInterval: TimeInterval = 60,
        idleRefreshInterval: TimeInterval = 5 * 60,
        staleAfter: TimeInterval = 15 * 60,
        archive: UsageArchive = UsageArchive(),
        disconnected: Set<String> = []
    ) {
        self.providers = providers
        self.refreshInterval = refreshInterval
        self.idleRefreshInterval = idleRefreshInterval
        self.staleAfter = staleAfter
        self.archive = archive

        // Through the wrapper's storage, not `self.disconnected`: the
        // property observer would save an empty archive over the real one.
        _disconnected = Published(initialValue: disconnected)
        lastGood = archive.load()
        if lastGood.keys.contains(where: disconnected.contains) {
            for id in disconnected { lastGood.removeValue(forKey: id) }
            archive.save(lastGood)
        }
        // Open on what we knew last time rather than on an empty ring; the
        // first fetch will either confirm it or replace it.
        snapshots = providers.filter { !disconnected.contains($0.id) }.map { provider in
            guard let remembered = lastGood[provider.id] else { return Self.placeholder(provider) }
            var snapshot = remembered.snapshot
            snapshot.status = .stale(since: remembered.fetchedAt)
            return snapshot
        }
    }

    /// Enough to list the providers in settings without exposing them.
    var providerSummaries: [ProviderSummary] {
        providers.map { provider in
            ProviderSummary(id: provider.id, name: provider.displayName,
                            glyph: provider.glyph,
                            account: disconnected.contains(provider.id) ? nil : provider.account(),
                            signIn: provider.signInRoute,
                            wasRefusedAccess: refusedAccess.contains(provider.id))
        }
    }

    func start() {
        refreshNow()

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Waking up is the one moment the numbers are guaranteed to be wrong.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        isRefreshing = false
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func tick() {
        let waited = lastAttempt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard Self.shouldRefresh(
            isBusy: isBusy(),
            sinceLastAttempt: waited,
            idleInterval: idleRefreshInterval
        ) else { return }
        refreshNow()
    }

    /// Poll at full rate while something is running; otherwise wait out the
    /// idle interval. Pure, so the schedule can be tested without a clock.
    static func shouldRefresh(
        isBusy: Bool,
        sinceLastAttempt: TimeInterval,
        idleInterval: TimeInterval
    ) -> Bool {
        isBusy || sinceLastAttempt >= idleInterval
    }

    func refreshNow() {
        guard !isRefreshing else {
            UsageLog.usage.notice("refresh skipped: one already in flight")
            return
        }
        isRefreshing = true
        lastAttempt = Date()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.isRefreshing = false
        }
    }

    func refresh() async {
        let live = providers.filter { !disconnected.contains($0.id) }
        let versions = connectionVersions
        refreshing = Set(live.map(\.id))
        defer { refreshing = [] }
        var next: [ProviderSnapshot] = []
        for provider in live {
            if let fresh = await snapshot(from: provider, version: versions[provider.id]) {
                next.append(fresh)
            }
        }
        // An earlier result can have been disconnected while a later provider
        // was awaiting its response. Do not put that reading back on screen.
        snapshots = ordered(next.filter { isCurrent($0.id, version: versions[$0.id]) })
        lastRefreshedAt = Date()
    }

    /// Refetch one provider, leaving the others alone: asking one cell for a
    /// fresh reading should not spend every other provider's rate-limit budget.
    func refresh(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              !disconnected.contains(providerID),
              !refreshing.contains(providerID) else { return }

        refreshing.insert(providerID)
        let version = connectionVersions[providerID]
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshing.remove(providerID) }
            guard let fresh = await self.snapshot(from: provider, version: version) else { return }
            if let index = self.snapshots.firstIndex(where: { $0.id == providerID }) {
                self.snapshots[index] = fresh
            }
            self.lastAttempt = Date()
            // A beat of visible work even when the answer was instant: a
            // spinner that flashes for one frame reads as a glitch.
            try? await Task.sleep(nanoseconds: 380_000_000)
        }
    }

    /// Forget one provider's readings entirely. Switching it off stops the
    /// *next* read; this also drops the archived one, so the numbers do not
    /// come back at the next launch.
    func forget(providerID: String) {
        connectionVersions[providerID] = UUID()
        refusedAccess.remove(providerID)
        snapshots.removeAll { $0.id == providerID }
        lastGood.removeValue(forKey: providerID)
        archive.forget(providerID)
    }

    /// Ask macOS for this provider's credential again: the remedy for a
    /// declined keychain prompt. Dropping the in-memory copy first is the
    /// part that matters, or the read is served from the cache and the prompt
    /// never returns.
    func reauthorize(providerID: String) {
        providers.first { $0.id == providerID }?.forgetCachedCredential()
        refresh(providerID: providerID)
    }

    /// Providers keep their configured order whatever order responses land in.
    private func ordered(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        let rank = Dictionary(uniqueKeysWithValues: providers.enumerated().map { ($1.id, $0) })
        return snapshots.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    private func isCurrent(_ providerID: String, version: UUID?) -> Bool {
        !Task.isCancelled && !disconnected.contains(providerID)
            && connectionVersions[providerID] == version
    }

    private func snapshot(from provider: UsageProvider, version: UUID?) async -> ProviderSnapshot? {
        guard isCurrent(provider.id, version: version) else { return nil }
        do {
            let fresh = try await provider.fetchSnapshot()
            guard isCurrent(provider.id, version: version) else { return nil }
            lastGood[provider.id] = (fresh, Date())
            archive.save(lastGood)
            refusedAccess.remove(provider.id)
            UsageLog.usage.debug("\(provider.id, privacy: .public): \(fresh.windows.count) window(s)")
            return fresh
        } catch {
            guard isCurrent(provider.id, version: version) else { return nil }
            UsageLog.usage.error("\(provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return degraded(provider: provider, error: error)
        }
    }

    /// A failed fetch never invents a number: it either re-shows the last good
    /// one marked stale, or shows the cell with no reading at all.
    private func degraded(provider: UsageProvider, error: Error) -> ProviderSnapshot {
        let status = Self.status(for: error)

        if case .accessDenied = status {
            refusedAccess.insert(provider.id)
        } else {
            refusedAccess.remove(provider.id)
        }

        // Some failures are statements about the account rather than a hiccup:
        // signed out, or a plan that meters nothing. The remembered reading is
        // dropped rather than dimmed.
        if Self.supersedesHistory(status) {
            lastGood[provider.id] = nil
            archive.save(lastGood)
            var empty = Self.placeholder(provider)
            empty.status = status
            return empty
        }

        guard let previous = lastGood[provider.id] else {
            var empty = Self.placeholder(provider)
            empty.status = status
            return empty
        }

        let age = Date().timeIntervalSince(previous.fetchedAt)
        var snapshot = previous.snapshot
        snapshot.status = age > staleAfter ? .stale(since: previous.fetchedAt) : previous.snapshot.status
        return snapshot
    }

    /// True when the new status makes any remembered reading untrue rather
    /// than merely old. A keychain refusal says nothing about the reading.
    static func supersedesHistory(_ status: ProviderStatus) -> Bool {
        switch status {
        case .needsAuth, .unsupported: return true
        case .accessDenied, .ok, .stale, .error: return false
        }
    }

    static func status(for error: Error) -> ProviderStatus {
        switch error {
        case UsageProviderError.needsAuth:
            return .needsAuth
        case UsageProviderError.credentialExpired:
            // The number was true when it was taken, and the token refreshes
            // itself the next time the owning tool runs.
            return .stale(since: Date())
        case UsageProviderError.rateLimited:
            return .stale(since: Date())
        case UsageProviderError.accessDenied:
            return .accessDenied
        case UsageProviderError.nothingMetered(let why):
            return .unsupported(why)
        case UsageProviderError.badResponse(let code):
            return .error("HTTP \(code)")
        default:
            return .error((error as NSError).localizedDescription)
        }
    }

    private static func placeholder(_ provider: UsageProvider) -> ProviderSnapshot {
        ProviderSnapshot(
            id: provider.id,
            displayName: provider.displayName,
            glyph: provider.glyph,
            fidelity: .official,
            status: .stale(since: .distantPast),
            windows: []
        )
    }
}
