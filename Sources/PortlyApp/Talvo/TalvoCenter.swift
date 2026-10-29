import AppKit
import Combine
import Foundation
import Network

/// The Talvo link, for the whole app: one token, one event stream, one copy of
/// the workspace that every Talvo view reads.
///
/// Talvo pushes nothing but a sequence number over the stream; on each one
/// Portly asks for the delta since the sequence it holds, so a dropped
/// connection loses nothing and the stream costs a few kilobytes an hour.
/// A dropped stream reconnects with a growing delay, and a wake from sleep or
/// a network coming back reconnects at once.
@MainActor
final class TalvoCenter: ObservableObject {
    static let shared = TalvoCenter()

    enum Connection: Equatable {
        /// No token on this Mac: Talvo is simply not part of this Portly.
        case off
        case connecting
        /// The stream is open; changes arrive as they happen.
        case live
        /// Between stream attempts, with what went wrong.
        case offline(String)
        /// Talvo refused the token. No retry until the credentials change.
        case refused(String)

        var isConfigured: Bool { self != .off }
    }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var identity: TalvoIdentity?
    @Published private(set) var data = TalvoWorkspaceData()
    @Published private(set) var lastSyncAt: Date?
    /// Detail reads, kept while the app runs and refreshed when a delta says
    /// the item moved.
    @Published private(set) var issueDetails: [String: TalvoIssueDetail] = [:]
    @Published private(set) var projectDetails: [String: TalvoProjectDetail] = [:]
    @Published private(set) var detailErrors: [String: String] = [:]

    /// The one bit the main window needs: is Talvo part of this Portly at
    /// all? Kept apart so the window does not redraw on every delta.
    let presence = TalvoPresence()

    private(set) var client: TalvoClient?
    private var streamTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    private var catchUpRequested = false
    private var backoff: TimeInterval = 1
    /// Bumped by every stop or restart; a loop whose generation moved on
    /// must not touch the state any more.
    private var generation = 0
    private var pathMonitor: NWPathMonitor?
    private var wasOnline = true
    private var cancellables: Set<AnyCancellable> = []
    private var saveWork: DispatchWorkItem?

    private static let maximumBackoff: TimeInterval = 30
    /// A stream without a heartbeat for this long is dead; Talvo pings every 25 s.
    private static let streamSilenceLimit: TimeInterval = 60

    private init() {
        $connection
            .map(\.isConfigured)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [presence] configured in presence.isConfigured = configured }
            .store(in: &cancellables)
    }

    var canWrite: Bool { identity?.canWrite ?? false }

    /// The Talvo site, for links out of Portly.
    var publicURL: URL? {
        identity?.publicUrl.flatMap(URL.init(string:)) ?? TalvoCredentials.serverURL
    }

    func webURL(forProject project: TalvoProject) -> URL? {
        publicURL?.appendingPathComponent("projets").appendingPathComponent(project.slug)
    }

    func webURL(forIssueIdentifier identifier: String) -> URL? {
        publicURL?.appendingPathComponent("issues").appendingPathComponent(identifier)
    }

    /// The issue a Talvo link points at (`…/issues/BLE-12`), when it is one
    /// of this server's and the issue is known here.
    func issueID(linkedBy url: URL) -> String? {
        guard let host = publicURL?.host, url.host == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[parts.count - 2] == "issues" else { return nil }
        return TalvoWorkspaceData.issueID(forIdentifier: parts[parts.count - 1], in: data)
    }

    // MARK: Lifecycle

    /// At launch: pick the saved credentials up and start syncing.
    func start() {
        guard client == nil, let url = TalvoCredentials.serverURL, let token = TalvoCredentials.readToken() else {
            connection = .off
            return
        }
        client = TalvoClient(baseURL: url, token: token)
        if let cached = TalvoCacheStore.load(), cached.server == url.absoluteString {
            data = cached.data
            identity = cached.identity
        }
        connection = .connecting
        watchEnvironment()
        startStream()
    }

    /// Check a pasted token against a server, and keep both when Talvo
    /// accepts them. Throws with what Talvo said otherwise.
    func connect(serverText: String, token: String) async throws -> TalvoIdentity {
        guard let url = TalvoClient.normalizedBaseURL(serverText) else {
            throw TalvoRequestError(kind: .invalidServer)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TalvoRequestError(kind: .unauthenticated) }
        let candidate = TalvoClient(baseURL: url, token: trimmed)
        let who = try await candidate.me()
        stop(clearingCredentials: false)
        TalvoCredentials.serverURL = url
        TalvoCredentials.saveToken(trimmed)
        client = candidate
        identity = who
        data = TalvoWorkspaceData()
        connection = .connecting
        watchEnvironment()
        startStream()
        return who
    }

    /// Forget the token and everything read with it.
    func disconnect() {
        stop(clearingCredentials: true)
        connection = .off
    }

    private func stop(clearingCredentials: Bool) {
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        catchUpTask?.cancel()
        catchUpTask = nil
        catchUpRequested = false
        saveWork?.cancel()
        saveWork = nil
        client = nil
        identity = nil
        data = TalvoWorkspaceData()
        issueDetails = [:]
        projectDetails = [:]
        detailErrors = [:]
        lastSyncAt = nil
        backoff = 1
        if clearingCredentials {
            TalvoCredentials.deleteToken()
            TalvoCredentials.serverURL = nil
            TalvoCacheStore.clear()
        }
    }

    /// Drop the current stream and open a new one now, after a wake or a
    /// network change. Also what the settings' Retry does.
    func reconnectNow() {
        guard client != nil else { return }
        if case .refused = connection { return }
        backoff = 1
        startStream()
    }

    private func watchEnvironment() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBack = online && !self.wasOnline
                self.wasOnline = online
                if cameBack { self.reconnectNow() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.portly.talvo.network"))
        pathMonitor = monitor
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconnectNow() }
            .store(in: &cancellables)
    }

    // MARK: The stream

    private func startStream() {
        generation += 1
        let myGeneration = generation
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.generation == myGeneration {
                guard let client = self.client else { return }
                do {
                    if self.identity == nil {
                        let who = try await client.me()
                        guard self.generation == myGeneration else { return }
                        self.identity = who
                    }
                    try await self.catchUp(client: client, generation: myGeneration)
                    guard self.generation == myGeneration else { return }
                    self.connection = .live
                    self.backoff = 1
                    let end = try await self.consumeStream(client: client)
                    guard self.generation == myGeneration else { return }
                    switch end {
                    case .closed:
                        // Talvo closed the stream (a deploy, most likely): come back quietly.
                        self.connection = .offline("Reconnecting…")
                    case .revoked:
                        self.connection = .refused("The token was revoked in Talvo.")
                        return
                    case .replaced:
                        // Too many devices on one token: leave room, try again later.
                        self.connection = .offline("Another device took this token's stream.")
                        self.backoff = Self.maximumBackoff
                    }
                } catch is CancellationError {
                    return
                } catch let error as TalvoRequestError {
                    guard self.generation == myGeneration else { return }
                    switch error.kind {
                    case .unauthenticated, .forbidden:
                        self.connection = .refused(error.localizedDescription)
                        return
                    default:
                        self.connection = .offline(error.localizedDescription)
                    }
                } catch {
                    guard self.generation == myGeneration else { return }
                    self.connection = .offline(error.localizedDescription)
                }
                let delay = self.backoff
                self.backoff = min(self.backoff * 2, Self.maximumBackoff)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Why a stream ended on its own.
    private enum StreamEnd {
        case closed
        case revoked
        case replaced
    }

    /// Reads events until the stream ends or stays silent for too long.
    private func consumeStream(client: TalvoClient) async throws -> StreamEnd {
        let silence = Self.streamSilenceLimit
        return try await withThrowingTaskGroup(of: StreamEnd.self) { group in
            let lastEvent = TalvoClock()
            group.addTask { @MainActor [weak self] in
                for try await event in client.events() {
                    await lastEvent.touch()
                    guard let self else { return .closed }
                    switch event {
                    case .seq(let seq):
                        if seq > self.data.seq { self.requestCatchUp() }
                    case .ping:
                        break
                    case .revoked:
                        return .revoked
                    case .replaced:
                        return .replaced
                    }
                }
                return .closed
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(silence / 2))
                    if await lastEvent.secondsSinceTouch() > silence {
                        throw TalvoRequestError(kind: .network("The Talvo stream went silent."))
                    }
                }
            }
            // The first child to finish ends both: the stream closed, or the
            // watchdog gave up on it.
            defer { group.cancelAll() }
            return try await group.next() ?? .closed
        }
    }

    // MARK: Catching up

    /// Bring the data up to the server's sequence: a delta when possible, a
    /// fresh bootstrap when Talvo says the gap is too old or we hold nothing.
    private func catchUp(client: TalvoClient, generation myGeneration: Int) async throws {
        if data.isLoaded {
            let delta = try await client.sync(since: data.seq)
            guard generation == myGeneration else { return }
            if delta.reset {
                let bootstrap = try await client.bootstrap()
                guard generation == myGeneration else { return }
                data.apply(bootstrap)
                issueDetails = [:]
                projectDetails = [:]
            } else if delta.seq > data.seq {
                data.apply(delta)
                await refreshTouchedDetails(delta.touched, client: client)
                guard generation == myGeneration else { return }
            }
        } else {
            let bootstrap = try await client.bootstrap()
            guard generation == myGeneration else { return }
            data.apply(bootstrap)
        }
        lastSyncAt = Date()
        scheduleSave()
    }

    /// A seq arrived: fetch the delta soon, once, however many arrive in a burst.
    private func requestCatchUp() {
        if catchUpTask != nil {
            catchUpRequested = true
            return
        }
        let myGeneration = generation
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, let client = self.client, self.generation == myGeneration else { return }
            do {
                try await self.catchUp(client: client, generation: myGeneration)
            } catch {
                // The stream loop notices a dead server; a one-off failure
                // is caught up by the next seq or reconnection.
            }
            self.catchUpTask = nil
            if self.catchUpRequested {
                self.catchUpRequested = false
                self.requestCatchUp()
            }
        }
    }

    /// Details on screen whose long text or activity changed are read again.
    private func refreshTouchedDetails(_ touched: TalvoSyncDelta.Touched, client: TalvoClient) async {
        for id in touched.issues where issueDetails[id] != nil {
            if let detail = try? await client.issue(id) { issueDetails[id] = detail }
        }
        for id in touched.projects where projectDetails[id] != nil {
            if let detail = try? await client.project(id) { projectDetails[id] = detail }
        }
    }

    // MARK: Details

    /// Read an issue in full. Cached; `force` reads it again.
    func loadIssueDetail(_ id: String, force: Bool = false) async {
        guard let client, force || issueDetails[id] == nil else { return }
        do {
            issueDetails[id] = try await client.issue(id)
            detailErrors.removeValue(forKey: id)
        } catch {
            detailErrors[id] = error.localizedDescription
        }
    }

    func loadProjectDetail(_ id: String, force: Bool = false) async {
        guard let client, force || projectDetails[id] == nil else { return }
        do {
            projectDetails[id] = try await client.project(id)
            detailErrors.removeValue(forKey: id)
        } catch {
            detailErrors[id] = error.localizedDescription
        }
    }

    func loadDocument(_ id: String) async throws -> TalvoDocumentDetail {
        guard let client else { throw TalvoRequestError(kind: .unauthenticated) }
        return try await client.document(id)
    }

    // MARK: Writes

    func setStatus(ofIssue id: String, to statusID: String) async throws {
        guard let client else { return }
        let issue = try await client.updateIssue(id, fields: ["status": statusID])
        data.issues[issue.id] = issue
        await loadIssueDetail(id, force: true)
    }

    func addComment(toIssue id: String, body: String) async throws {
        guard let client else { return }
        _ = try await client.addComment(issue: id, body: body)
        await loadIssueDetail(id, force: true)
    }

    // MARK: Cache on disk

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = TalvoCacheStore.Cached(
            server: client?.baseURL.absoluteString ?? "",
            identity: identity,
            data: data
        )
        let work = DispatchWorkItem { TalvoCacheStore.save(snapshot) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }
}

/// Whether a Talvo token is set on this Mac, and nothing else: what the
/// toolbar needs to decide if the Talvo button exists.
final class TalvoPresence: ObservableObject {
    @Published fileprivate(set) var isConfigured = false
}

/// When the stream last said anything, shared between the reader and its watchdog.
private actor TalvoClock {
    private var last = Date()

    func touch() { last = Date() }

    func secondsSinceTouch() -> TimeInterval { Date().timeIntervalSince(last) }
}

/// The last workspace read, kept beside Portly's other files so the next
/// launch asks for a delta instead of the whole bootstrap.
enum TalvoCacheStore {
    struct Cached: Codable {
        var server: String
        var identity: TalvoIdentity?
        var data: TalvoWorkspaceData
    }

    static var url: URL {
        StudioStore.defaultURL.deletingLastPathComponent().appendingPathComponent("talvo-cache.json")
    }

    static func load() -> Cached? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    static func save(_ cached: Cached) {
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
