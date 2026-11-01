import AppKit
import Combine
import Foundation
import SwiftUI

/// What the main window needs from the Things panel, kept apart so the window
/// does not redraw every time a branch moves.
@MainActor
final class ThingsChrome: ObservableObject {
    @Published fileprivate(set) var isVisible: Bool
    /// Branches waiting for you (finished, or asking something), for the
    /// toolbar button when the panel is closed.
    @Published fileprivate(set) var needsYouCount = 0
    /// The panel floats over the window, so its width is yours to pick.
    @Published private(set) var width: CGFloat

    static let defaultWidth: CGFloat = 288
    static let widthRange: ClosedRange<CGFloat> = 248...560

    fileprivate static let visibleKey = "thingsPanelVisible"
    private static let widthKey = "thingsPanelWidth"

    init() {
        isVisible = UserDefaults.standard.bool(forKey: Self.visibleKey)
        let stored = UserDefaults.standard.double(forKey: Self.widthKey)
        width = stored > 0 ? Self.clamped(stored) : Self.defaultWidth
    }

    func setWidth(_ value: CGFloat) {
        width = Self.clamped(value)
        UserDefaults.standard.set(Double(width), forKey: Self.widthKey)
    }

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }
}

/// The Things panel's brain: the followed area's to-dos, the branches of
/// work hanging under them, and the sorting agent that creates those.
///
/// Nothing here runs on a loop. It wakes when Claude Code rewrites a session
/// file (which it does on every state change), considers only the Claude
/// Code processes running inside a Portly terminal, and starts the sorting
/// agent only for a new prompt in a terminal that is not linked yet. Things
/// is read while the panel is open, and right before a prompt is sorted.
@MainActor
final class ThingsCenter: ObservableObject {
    static let shared = ThingsCenter()

    enum Availability: Equatable {
        case unknown
        /// Things 3 is not installed, or has never been opened.
        case missing
        case unreadable(String)
        case ready
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var areas: [ThingsArea] = []
    @Published private(set) var area: ThingsArea?
    @Published private(set) var tasks: [ThingsTask] = []
    @Published private(set) var urlToken: String?
    @Published private(set) var branches: [ThingsBranch] = []
    /// Prompts the sorting agent is reading, shown at the top of the panel.
    @Published private(set) var pending: [TriageJob] = []
    @Published private(set) var autoSort = true
    /// To-dos ticked here, hidden until Things confirms.
    @Published private(set) var completing: Set<String> = []
    /// The last thing that went wrong, shown for a moment in the footer.
    @Published private(set) var notice: String?

    let chrome = ThingsChrome()

    static let maximumConcurrentSorts = 2
    static let flow = Animation.spring(duration: 0.5, bounce: 0)

    private var state = ThingsPanelState()
    private let stateURL: URL
    private var saveWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?

    private var databaseURL: URL?
    private var databaseStamp: [Date?] = []
    private var databaseTimer: Timer?
    private var reading = false

    private var sessionsSource: DispatchSourceFileSystemObject?
    /// The session files of the Claude Code running in Portly terminals:
    /// a status written in place only shows on the file itself.
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var scanDebounce: DispatchWorkItem?
    private var livenessTimer: Timer?
    private var retryTimer: Timer?
    private var scanning = false
    private var rescanRequested = false
    private let scanQueue = DispatchQueue(label: "portly.things.activity", qos: .utility)

    /// Each terminal's Claude Code status at the last scan.
    private var lastStatus: [String: AgentStatus] = [:]
    /// Terminals whose new busy period still needs its prompt read.
    private var promptChecks: [String: Int] = [:]
    private var queuedJobs: [(job: TriageJob, request: ThingsTriage.Request)] = []
    private var runningSorts = 0

    private init(stateURL: URL = StudioStore.defaultURL.deletingLastPathComponent().appendingPathComponent("things.json")) {
        self.stateURL = stateURL
    }

    // MARK: - Lifecycle

    func start() {
        if let data = try? Data(contentsOf: stateURL),
           let loaded = try? JSONDecoder.thingsPanel.decode(ThingsPanelState.self, from: data) {
            state = loaded
            state.settleAfterLaunch()
        }
        branches = state.branches
        autoSort = state.autoSort
        refreshChrome()
        watchSessions()
        if chrome.isVisible { startReadingThings() }
    }

    func stop() {
        databaseTimer?.invalidate()
        livenessTimer?.invalidate()
        retryTimer?.invalidate()
        sessionsSource?.cancel()
        sessionsSource = nil
        fileSources.values.forEach { $0.cancel() }
        fileSources.removeAll()
        saveNow()
    }

    // MARK: - Panel

    var rows: [ThingsBoard.Row] {
        ThingsBoard.rows(tasks: tasks.filter { !completing.contains($0.id) }, branches: branches)
    }

    var canEditThings: Bool { urlToken != nil }

    func toggleVisible() {
        setVisible(!chrome.isVisible)
    }

    func setVisible(_ visible: Bool) {
        guard visible != chrome.isVisible else { return }
        chrome.isVisible = visible
        UserDefaults.standard.set(visible, forKey: ThingsChrome.visibleKey)
        if visible { startReadingThings() } else { stopReadingThings() }
    }

    func selectArea(_ id: String) {
        guard id != state.areaID else { return }
        state.areaID = id
        scheduleSave()
        reloadThings()
    }

    func setAutoSort(_ enabled: Bool) {
        autoSort = enabled
        state.autoSort = enabled
        scheduleSave()
    }

    // MARK: - Things actions

    func addTask(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let area else { return }
        guard canEditThings else { return showNotice(Self.urlsOffNotice) }
        guard let url = ThingsLinks.add(title: trimmed, areaID: area.id) else { return }
        ThingsLinks.openInBackground(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.reloadThings() }
    }

    func complete(_ task: ThingsTask) {
        guard let token = urlToken else { return showNotice(Self.urlsOffNotice) }
        guard let url = ThingsLinks.complete(taskID: task.id, token: token) else { return }
        _ = withAnimation(Motion.state) { completing.insert(task.id) }
        ThingsLinks.openInBackground(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.reloadThings() }
        // Things did not take it (a wrong token, Things quit): show it again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.completing.contains(task.id) else { return }
            _ = withAnimation(Motion.state) { self.completing.remove(task.id) }
            self.showNotice("Things did not confirm the to-do as done.")
        }
    }

    func openInThings(_ task: ThingsTask) {
        guard let url = ThingsLinks.show(taskID: task.id) else { return }
        NSWorkspace.shared.open(url)
    }

    func openThings() {
        guard let url = URL(string: "things:///show?id=today") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Branch actions

    func reveal(_ branch: ThingsBranch) {
        guard StudioWorkspace.shared.revealTerminal(paneID: branch.paneID) else {
            return showNotice("That terminal was closed.")
        }
        WindowOpener.openMainWindow()
    }

    func markReviewed(_ branch: ThingsBranch) {
        updateBranch(branch.id) { $0.state = .done }
    }

    func markNotReviewed(_ branch: ThingsBranch) {
        updateBranch(branch.id) { $0.state = .review }
    }

    func remove(_ branch: ThingsBranch) {
        withAnimation(Self.flow) { branches.removeAll { $0.id == branch.id } }
        persistBranches()
    }

    func move(_ branch: ThingsBranch, to task: ThingsTask) {
        updateBranch(branch.id) { $0.taskID = task.id }
    }

    /// Hang the terminal on screen under a to-do, for when the sorting agent
    /// missed it. A terminal already followed moves rather than doubles.
    func linkTerminalOnScreen(to task: ThingsTask) {
        guard let paneID = StudioWorkspace.shared.terminalOnScreen() else {
            return showNotice("Open a terminal first, then link it.")
        }
        if let active = branches.first(where: { $0.paneID == paneID && $0.isActive }) {
            return move(active, to: task)
        }
        let now = Date()
        let branch = ThingsBranch(
            id: Self.newBranchID(),
            taskID: task.id,
            label: "Travail en cours",
            paneID: paneID,
            state: Self.branchState(for: lastStatus[paneID]),
            createdAt: now,
            updatedAt: now
        )
        withAnimation(Self.flow) { branches.append(branch) }
        persistBranches()
    }

    func terminalName(for branch: ThingsBranch) -> String {
        StudioWorkspace.shared.terminalName(paneID: branch.paneID) ?? "Terminal closed"
    }

    // MARK: - Reading Things

    private func startReadingThings() {
        reloadThings()
        databaseTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfThingsChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        databaseTimer = timer
    }

    private func stopReadingThings() {
        databaseTimer?.invalidate()
        databaseTimer = nil
    }

    /// Two `stat` calls: Things writes to the WAL file first, and folds it
    /// into the main file now and then.
    private func reloadIfThingsChanged() {
        guard let url = databaseURL ?? ThingsDatabase.locate() else { return }
        let stamp = [url, URL(fileURLWithPath: url.path + "-wal")].map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        guard stamp != databaseStamp else { return }
        databaseStamp = stamp
        reloadThings()
    }

    func reloadThings(then completion: (() -> Void)? = nil) {
        guard !reading else {
            if let completion { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reloadThings(then: completion) } }
            return
        }
        reading = true
        let picked = state.areaID
        let followed = Set(branches.map(\.taskID))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<(URL, ThingsDatabase.Snapshot, Set<String>), Error>
            if let url = ThingsDatabase.locate() {
                result = Result {
                    let snapshot = try ThingsDatabase.read(at: url, pickedAreaID: picked)
                    let open = Set(snapshot.tasks.map(\.id))
                    let closed = try ThingsDatabase.closedTasks(among: followed.subtracting(open), at: url)
                    return (url, snapshot, closed)
                }
            } else {
                result = .failure(ThingsDatabaseError.notInstalled)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    self.apply(result)
                    completion?()
                }
            }
        }
    }

    private func apply(_ result: Result<(URL, ThingsDatabase.Snapshot, Set<String>), Error>) {
        switch result {
        case .failure(let error as ThingsDatabaseError) where error == .notInstalled:
            availability = .missing
        case .failure(let error):
            availability = .unreadable(error.localizedDescription)
        case .success(let (url, snapshot, closed)):
            databaseURL = url
            availability = .ready
            if areas != snapshot.areas { areas = snapshot.areas }
            if area != snapshot.area { area = snapshot.area }
            if urlToken != snapshot.urlToken { urlToken = snapshot.urlToken }
            let open = Set(snapshot.tasks.map(\.id))
            withAnimation(Motion.reorder) {
                if tasks != snapshot.tasks { tasks = snapshot.tasks }
                completing.formIntersection(open)
                // A to-do done or deleted in Things takes its branches with it.
                if !closed.isEmpty { branches.removeAll { closed.contains($0.taskID) } }
            }
            if !closed.isEmpty { persistBranches() }
        }
    }

    // MARK: - Watching Claude Code

    private func watchSessions() {
        let directory = ClaudeActivity.claudeDirectory.appendingPathComponent("sessions", isDirectory: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // No Claude Code session yet on this Mac: look again later.
            retryTimer?.invalidate()
            let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchSessions() }
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        sessionsSource = source
        scheduleScan()
    }

    /// A state change writes several file events; one scan covers them.
    private func scheduleScan() {
        scanDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scanActivity() }
        }
        scanDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func scanActivity() {
        guard !scanning else {
            rescanRequested = true
            return
        }
        let terminals = StudioWorkspace.shared.watchedTerminals()
        let followed = Set(branches.filter(\.isActive).map(\.paneID))
        guard !terminals.isEmpty || !followed.isEmpty else { return }
        scanning = true
        let shells = Dictionary(terminals.map { ($0.shellPID, $0.paneID) }, uniquingKeysWith: { first, _ in first })
        scanQueue.async { [weak self] in
            var byTerminal: [String: ClaudeActivity.Session] = [:]
            for session in ClaudeActivity.liveSessions() {
                guard let paneID = ClaudeActivity.terminal(of: session.pid, shells: shells) else { continue }
                // Two Claude Code in one terminal: the busy one is the news.
                if let existing = byTerminal[paneID], existing.status == .busy { continue }
                byTerminal[paneID] = session
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    self.apply(activity: byTerminal, terminals: terminals)
                    if self.rescanRequested {
                        self.rescanRequested = false
                        self.scheduleScan()
                    }
                }
            }
        }
    }

    private func apply(activity: [String: ClaudeActivity.Session], terminals: [WatchedTerminal]) {
        var changed = false
        let followed = Set(branches.filter(\.isActive).map(\.paneID))
        for paneID in Set(activity.keys).union(followed) {
            let status = activity[paneID]?.status ?? .gone
            let previous = lastStatus[paneID]
            lastStatus[paneID] = status
            if status == .busy, previous != .busy, let session = activity[paneID] {
                promptChecks[paneID] = 0
                checkPrompt(paneID: paneID, session: session, terminals: terminals)
            }
            if let index = branches.firstIndex(where: { $0.paneID == paneID && $0.isActive }) {
                let next = ThingsBranch.next(branches[index].state, status: status)
                if next != branches[index].state {
                    withAnimation(Motion.state) {
                        branches[index].state = next
                        branches[index].updatedAt = Date()
                    }
                    changed = true
                }
            }
        }
        for paneID in lastStatus.keys where activity[paneID] == nil && !followed.contains(paneID) {
            lastStatus.removeValue(forKey: paneID)
        }
        if changed { persistBranches() }
        watchSessionFiles(of: Array(activity.values))
        updateLiveness()
    }

    /// Follow exactly the files of the sessions found in Portly terminals,
    /// whether Claude Code replaces them or writes them in place.
    private func watchSessionFiles(of sessions: [ClaudeActivity.Session]) {
        let directory = ClaudeActivity.claudeDirectory.appendingPathComponent("sessions", isDirectory: true)
        let wanted = Set(sessions.map { directory.appendingPathComponent("\($0.pid).json").path })
        for (path, source) in fileSources where !wanted.contains(path) {
            source.cancel()
            fileSources.removeValue(forKey: path)
        }
        for path in wanted where fileSources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
                queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Replaced or removed: this descriptor is stale; the next
                    // scan opens the new file.
                    if let source, !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
                        source.cancel()
                        self.fileSources.removeValue(forKey: path)
                    }
                    self.scheduleScan()
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            fileSources[path] = source
        }
    }

    /// A Claude Code killed without a word leaves its file saying "busy";
    /// while something is followed as working, look every few seconds.
    private func updateLiveness() {
        let needed = branches.contains { $0.state == .working || $0.state == .waiting }
        if needed, livenessTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scanActivity() }
            }
            RunLoop.main.add(timer, forMode: .common)
            livenessTimer = timer
        } else if !needed, let timer = livenessTimer {
            timer.invalidate()
            livenessTimer = nil
        }
    }

    // MARK: - Sorting

    /// Read what you just asked in that terminal. Claude Code may flip to
    /// busy a beat before the prompt reaches the transcript: try a few times.
    private func checkPrompt(paneID: String, session: ClaudeActivity.Session, terminals: [WatchedTerminal]) {
        scanQueue.async { [weak self] in
            let prompt = ClaudeActivity.transcriptURL(sessionID: session.sessionID, cwd: session.cwd)
                .flatMap(ClaudeActivity.latestHumanPrompt(transcript:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let prompt else {
                        let attempts = (self.promptChecks[paneID] ?? 0) + 1
                        self.promptChecks[paneID] = attempts
                        guard attempts < 5, self.lastStatus[paneID] == .busy else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.checkPrompt(paneID: paneID, session: session, terminals: terminals)
                        }
                        return
                    }
                    self.promptChecks.removeValue(forKey: paneID)
                    self.received(prompt, paneID: paneID, session: session, terminals: terminals)
                }
            }
        }
    }

    private func received(_ prompt: ClaudeActivity.HumanPrompt, paneID: String, session: ClaudeActivity.Session, terminals: [WatchedTerminal]) {
        guard state.seenPrompts[paneID] != prompt.id else { return }
        state.seenPrompts[paneID] = prompt.id
        scheduleSave()
        // A linked terminal is simply working again; only a free one is sorted.
        guard autoSort,
              !branches.contains(where: { $0.paneID == paneID && $0.isActive }),
              !pending.contains(where: { $0.paneID == paneID }),
              !queuedJobs.contains(where: { $0.job.paneID == paneID })
        else { return }
        let projectName = terminals.first { $0.paneID == paneID }?.projectID
            .flatMap { id in Supervisor.shared.projects.first { $0.id == id }?.name }
        let job = TriageJob(id: Self.newBranchID(), paneID: paneID, excerpt: ThingsBoard.excerpt(of: prompt.text))
        let request = ThingsTriage.Request(prompt: prompt.text, directory: session.cwd, projectName: projectName)
        withAnimation(Self.flow) { pending.append(job) }
        queuedJobs.append((job, request))
        startQueuedSorts()
    }

    private func startQueuedSorts() {
        while runningSorts < Self.maximumConcurrentSorts, !queuedJobs.isEmpty {
            let (job, request) = queuedJobs.removeFirst()
            runningSorts += 1
            // The freshest list: a to-do noted on the phone a minute ago counts.
            reloadThings { [weak self] in
                guard let self else { return }
                let tasks = self.tasks.filter { !self.completing.contains($0.id) }
                guard !tasks.isEmpty else {
                    self.finish(job, with: .success(.unrelated))
                    return
                }
                Task {
                    let result: Result<ThingsTriage.Verdict, Error>
                    do {
                        result = .success(try await ThingsTriage.run(tasks: tasks, request: request))
                    } catch {
                        result = .failure(error)
                    }
                    self.finish(job, with: result)
                }
            }
        }
    }

    private func finish(_ job: TriageJob, with result: Result<ThingsTriage.Verdict, Error>) {
        runningSorts -= 1
        defer { startQueuedSorts() }
        switch result {
        case .failure(let error):
            withAnimation(Self.flow) { pending.removeAll { $0.id == job.id } }
            showNotice(error.localizedDescription)
        case .success(.unrelated):
            withAnimation(Self.flow) { pending.removeAll { $0.id == job.id } }
        case .success(.task(let taskID, let label)):
            // Linked by hand meanwhile, or the to-do vanished: nothing to add.
            guard tasks.contains(where: { $0.id == taskID }),
                  !branches.contains(where: { $0.paneID == job.paneID && $0.isActive }) else {
                withAnimation(Self.flow) { pending.removeAll { $0.id == job.id } }
                return
            }
            let now = Date()
            let branch = ThingsBranch(
                id: job.id,
                taskID: taskID,
                label: label,
                paneID: job.paneID,
                state: Self.branchState(for: lastStatus[job.paneID]),
                createdAt: now,
                updatedAt: now
            )
            // One transaction: the pending row and the branch share an id,
            // so the row travels to its to-do and becomes the branch.
            withAnimation(Self.flow) {
                pending.removeAll { $0.id == job.id }
                branches.append(branch)
            }
            persistBranches()
            updateLiveness()
        }
    }

    // MARK: - Helpers

    private static func branchState(for status: AgentStatus?) -> ThingsBranch.State {
        switch status {
        case .busy: return .working
        case .waiting: return .waiting
        case .idle, .gone, nil: return .review
        }
    }

    private static func newBranchID() -> String {
        "br_" + String(UUID().uuidString.prefix(8)).lowercased()
    }

    static let urlsOffNotice = "Turn on Things URLs in Things → Settings → General to tick and add to-dos from Portly."

    private func updateBranch(_ id: String, _ change: (inout ThingsBranch) -> Void) {
        guard let index = branches.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Motion.state) {
            change(&branches[index])
            branches[index].updatedAt = Date()
        }
        persistBranches()
    }

    private func persistBranches() {
        state.branches = branches
        refreshChrome()
        scheduleSave()
    }

    private func refreshChrome() {
        let count = branches.filter { $0.state == .review || $0.state == .waiting }.count
        if chrome.needsYouCount != count { chrome.needsYouCount = count }
    }

    private func showNotice(_ message: String) {
        withAnimation(Motion.banner) { notice = message }
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(Motion.banner) { self.notice = nil }
            }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        state.branches = branches
        // Only the terminals that still exist, so the file does not grow forever.
        let live = Set(StudioWorkspace.shared.config.sessions.flatMap { $0.panes.map(\.id) })
            .union(StudioWorkspace.shared.config.terminalTabs.map(\.id))
        state.seenPrompts = state.seenPrompts.filter { live.contains($0.key) }
        guard let data = try? JSONEncoder.thingsPanel.encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var thingsPanel: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var thingsPanel: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
