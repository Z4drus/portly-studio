import AppKit
import Foundation
import PortlyCore
import SwiftTerm
import SwiftUI

/// Keyboard commands routed from the menu bar to whichever session is showing.
enum StudioCommand: Equatable {
    case newSession
    case newPane(PaneKind)
    case splitRight
    case splitDown
    case closePane
    case toggleZoom
    case focusNext
    case focusPrevious
    case biggerText
    case smallerText
    case resetText
    case toggleQuickTerminal
    case editEnvironment
    case clearTerminal
}

/// What a pane is up to, as far as the sidebar can tell from its output.
enum PaneActivity: Equatable {
    case idle
    /// Output within the last few seconds: the agent (or a command) is busy.
    case working
    /// Was working, went quiet, and nobody has looked at the session since.
    case finished
}

/// Owns every coding session and terminal pane in the app.
///
/// Sessions persist their shape (panes, splits, focus) in `studio.json`; the
/// shells themselves are respawned lazily the first time a restored session is
/// shown. Everything here runs on the main thread.
final class StudioWorkspace: ObservableObject {
    static let shared = StudioWorkspace()

    @Published private(set) var config: StudioConfig
    /// The session currently on screen, target of the keyboard commands.
    @Published var activeSessionID: String?
    /// The project the detail area is about, target of the quick terminal.
    @Published var activeProjectID: String?
    @Published var quickTerminalVisible = false
    /// The project whose environment panel floats over the detail area.
    @Published var envPanelProjectID: String?
    /// Set when the workspace wants the main window to navigate somewhere.
    @Published var pendingSelection: MainView.Selection?
    /// Bumped on runtime changes that the sidebar should reflect.
    @Published private(set) var revision = 0
    /// Per-pane activity, re-evaluated every second and published on change only.
    @Published private(set) var paneActivity: [String: PaneActivity] = [:]
    /// A sidebar double-click asked to rename this session inline.
    @Published var renameRequest: String?
    /// The session's toolbar menu asked to rename it in the session bar.
    @Published var sessionBarRenameRequest: String?
    /// True while the free terminal is on screen: its tabs count as seen,
    /// and the keyboard commands go to them.
    @Published var terminalWorkspaceVisible = false
    private var reopenedAtLaunch = false
    private var preparedSidebar = false
    /// Seconds until the next idle-project sweep, counted by the activity ticker.
    private var autoArchiveCountdown = 60

    private let store: StudioStore
    private var paneRuntimes: [String: TerminalPaneRuntime] = [:]
    private var quickRuntimes: [String: TerminalPaneRuntime] = [:]
    /// The free terminal's shells, by tab id.
    private var tabRuntimes: [String: TerminalPaneRuntime] = [:]

    /// The project id the free terminal's shells report: none of the real ones.
    static let terminalWorkspaceProjectID = "portly-terminal"

    private var keyMonitor: Any?
    private var activityTicker: Timer?

    private init(store: StudioStore = StudioStore()) {
        self.store = store
        config = store.config
        installKeyMonitor()
        startActivityTicker()
    }

    // MARK: - Project activity

    /// Writes closer together than this are dropped: the sidebar asks about a
    /// day, so a busy agent must not rewrite the config every second.
    private static let activityResolution: TimeInterval = 5 * 60

    /// When the project was last worked on, as far as Portly knows.
    func lastActivity(forProject projectID: String) -> Date? {
        config.projectActivity[projectID]
    }

    /// Record that the project is being worked on right now.
    func touchProject(_ projectID: String, now: Date = Date()) {
        if let previous = config.projectActivity[projectID],
           now.timeIntervalSince(previous) < Self.activityResolution {
            return
        }
        mutate { $0.projectActivity[projectID] = now }
    }

    /// Once per launch, before the sidebar is drawn: bring the activity dates
    /// up to date with what the Claude conversations say, forget projects that
    /// no longer exist, and archive the ones idle for too long.
    ///
    /// Configurations written before version 2 dated projects by their
    /// transcripts' modification times, which Claude Code moves on every
    /// resume, so those dates are replaced rather than trusted.
    func prepareSidebarAtLaunch(projects: [Project]) {
        // No projects most likely means a config that could not be read; the
        // archive and the order must survive until it can.
        guard !preparedSidebar, !projects.isEmpty else { return }
        preparedSidebar = true
        let exchanges = lastExchanges(projects: projects)
        let known = Set(projects.map(\.id))
        mutate { config in
            config.projectActivity = config.projectActivity.filter { known.contains($0.key) }
            config.archivedProjects.formIntersection(known)
            if config.version < StudioConfig.currentVersion {
                for (projectID, date) in exchanges { config.projectActivity[projectID] = date }
                config.version = StudioConfig.currentVersion
            } else {
                for (projectID, date) in exchanges where date > (config.projectActivity[projectID] ?? .distantPast) {
                    config.projectActivity[projectID] = date
                }
            }
            config.projectOrder = SidebarVisibility.complete(config.projectOrder, projects: projects)
        }
        autoArchiveIdleProjects()
    }

    /// The last real exchange in each project's Claude conversations, or the
    /// session's creation when it never had one. One short tail read per agent
    /// pane, which also catches work done while Portly was closed.
    private func lastExchanges(projects: [Project]) -> [String: Date] {
        var latest: [String: Date] = [:]
        for session in config.sessions {
            guard let project = projects.first(where: { $0.id == session.projectID }) else { continue }
            let root = NSString(string: project.root).expandingTildeInPath
            let exchanges = session.panes.compactMap { pane in
                pane.agentSessionID.flatMap { ClaudeTranscripts.lastExchange(sessionID: $0, projectRoot: root) }
            }
            let date = ([session.createdAt] + exchanges).max() ?? session.createdAt
            if date > (latest[project.id] ?? .distantPast) { latest[project.id] = date }
        }
        return latest
    }

    // MARK: - Sidebar order and archive

    func isArchived(_ projectID: String) -> Bool {
        config.archivedProjects.contains(projectID)
    }

    /// The projects the sidebar lists, in its order.
    func sidebarProjects(_ projects: [Project]) -> [Project] {
        SidebarVisibility.ordered(projects, order: config.projectOrder)
            .filter { !config.archivedProjects.contains($0.id) }
    }

    /// The projects waiting in the archive.
    func archivedProjects(_ projects: [Project]) -> [Project] {
        projects.filter { config.archivedProjects.contains($0.id) }
    }

    /// Put a project away. Its sessions and servers are left as they are.
    func archiveProject(_ projectID: String) {
        guard !isArchived(projectID) else { return }
        mutate { $0.archivedProjects.insert(projectID) }
        if activeProjectID == projectID { quickTerminalVisible = false }
        if envPanelProjectID == projectID { envPanelProjectID = nil }
    }

    /// Back in the sidebar, at the top where it will be seen.
    func unarchiveProject(_ projectID: String) {
        let projects = Supervisor.shared.projects
        mutate {
            $0.archivedProjects.remove(projectID)
            $0.projectOrder = SidebarVisibility.movingToTop(projectID, in: $0.projectOrder, projects: projects)
        }
        touchProject(projectID)
    }

    func moveProjectToTop(_ projectID: String) {
        let projects = Supervisor.shared.projects
        let next = SidebarVisibility.movingToTop(projectID, in: config.projectOrder, projects: projects)
        guard next != config.projectOrder else { return }
        mutate { $0.projectOrder = next }
    }

    /// A dragged project takes the place of the one it passes over.
    func moveProject(_ projectID: String, onto targetID: String) {
        let projects = Supervisor.shared.projects
        let next = SidebarVisibility.moving(projectID, onto: targetID, in: config.projectOrder, projects: projects)
        guard next != config.projectOrder else { return }
        mutate { $0.projectOrder = next }
    }

    /// One step up (-1) or down (+1) among the projects the sidebar shows.
    func moveProject(_ projectID: String, by offset: Int, among visible: [String]) {
        let projects = Supervisor.shared.projects
        let next = SidebarVisibility.moving(projectID, by: offset, among: visible, in: config.projectOrder, projects: projects)
        guard next != config.projectOrder else { return }
        mutate { $0.projectOrder = next }
    }

    /// A server just started, by hand or on its own: its project comes back
    /// from the archive if it was there, and goes to the top of the sidebar,
    /// where it stays after the server stops.
    func projectServerStarted(_ projectID: String) {
        if isArchived(projectID) {
            unarchiveProject(projectID)
        } else {
            moveProjectToTop(projectID)
        }
    }

    func setAutoArchiveDays(_ days: Int) {
        mutate { $0.autoArchiveDays = max(0, days) }
        autoArchiveIdleProjects()
    }

    /// Archive every project idle for longer than the setting allows.
    func autoArchiveIdleProjects(now: Date = Date()) {
        let days = config.autoArchiveDays
        guard days > 0 else { return }
        let supervisor = Supervisor.shared
        let running = Set(supervisor.runtimes.values.filter(\.isRunning).map(\.projectID))
        let idle = supervisor.projects
            .filter { project in
                !config.archivedProjects.contains(project.id)
                    && SidebarVisibility.shouldAutoArchive(
                        lastActivity: config.projectActivity[project.id],
                        hasRunningServer: running.contains(project.id),
                        isWorking: isWorking(projectID: project.id, now: now),
                        isSelected: activeProjectID == project.id,
                        afterDays: days,
                        now: now
                    )
            }
            .map(\.id)
        guard !idle.isEmpty else { return }
        mutate { $0.archivedProjects.formUnion(idle) }
    }

    private func isWorking(projectID: String, now: Date) -> Bool {
        paneRuntimes.values.contains {
            $0.projectID == projectID && $0.isProducingOutput(within: KeepAwake.workingWindow, now: now)
        }
    }

    /// Bring a project back from the archive: it returns to the top of the
    /// sidebar, and a coding session opens on it. Its servers are listed but
    /// left alone; starting one is still the user's call.
    @discardableResult
    func revealProject(_ projectID: String) -> TerminalSession {
        if isArchived(projectID) {
            unarchiveProject(projectID)
        } else {
            touchProject(projectID)
        }
        let existing = sessions(for: projectID).max { $0.createdAt < $1.createdAt }
        return existing ?? createSession(projectID: projectID)
    }

    // MARK: - Activity

    private func startActivityTicker() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.evaluateActivity() }
        activityTicker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func evaluateActivity(now: Date = Date()) {
        var next = paneActivity
        var changed = false
        for (id, runtime) in paneRuntimes.merging(tabRuntimes, uniquingKeysWith: { first, _ in first }) {
            let working = runtime.isProducingOutput(within: KeepAwake.workingWindow, now: now)
            let previous = paneActivity[id] ?? .idle
            var state = previous
            if working {
                state = .working
            } else if previous == .working {
                state = isOnScreen(paneID: id) ? .idle : .finished
            } else if previous == .finished, isOnScreen(paneID: id) {
                state = .idle
            }
            if state != previous {
                next[id] = state
                changed = true
            }
            if working, runtime.projectID != Self.terminalWorkspaceProjectID {
                touchProject(runtime.projectID, now: now)
            }
        }
        for id in next.keys where paneRuntimes[id] == nil && tabRuntimes[id] == nil {
            next.removeValue(forKey: id)
            changed = true
        }
        if changed { paneActivity = next }
        autoArchiveCountdown -= 1
        if autoArchiveCountdown <= 0 {
            autoArchiveCountdown = 60
            if preparedSidebar { autoArchiveIdleProjects(now: now) }
        }
    }

    private func isOnScreen(paneID: String) -> Bool {
        guard NSApp.isActive else { return false }
        if tabRuntimes[paneID] != nil {
            return terminalWorkspaceVisible && config.activeTerminalTabID == paneID
        }
        guard let sessionID = activeSessionID, let session = session(sessionID) else { return false }
        return session.layout.contains(paneID)
    }

    func activity(for paneID: String) -> PaneActivity {
        paneActivity[paneID] ?? .idle
    }

    /// Working beats finished beats idle, across the session's panes.
    func activity(for session: TerminalSession) -> PaneActivity {
        let states = session.panes.map { activity(for: $0.id) }
        if states.contains(.working) { return .working }
        if states.contains(.finished) { return .finished }
        return .idle
    }

    /// Panes (sessions and quick terminals) with output in the last few seconds.
    /// `agentsOnly` leaves out shells and quick terminals, whose output can
    /// be a log that never stops.
    func workingPaneCount(now: Date = Date(), agentsOnly: Bool = false) -> Int {
        let all = agentsOnly
            ? paneRuntimes.values.filter { $0.kind == .agent }
            : Array(paneRuntimes.values) + Array(quickRuntimes.values) + Array(tabRuntimes.values)
        return all.filter { $0.isProducingOutput(within: KeepAwake.workingWindow, now: now) }.count
    }

    // MARK: - Free terminal

    var terminalTabs: [TerminalTab] { config.terminalTabs }

    /// The tab on show: the one last selected, or the first.
    var activeTerminalTab: TerminalTab? {
        config.terminalTabs.first { $0.id == config.activeTerminalTabID } ?? config.terminalTabs.first
    }

    var terminalFontSize: Double { config.terminalFontSize ?? config.fontSize }

    /// True while a free-terminal shell is streaming output, for the sidebar.
    var isTerminalWorkspaceWorking: Bool {
        config.terminalTabs.contains { activity(for: $0.id) == .working }
    }

    /// A new tab next to the active one, starting in `directory` or at home.
    @discardableResult
    func createTerminalTab(directory: String? = nil) -> TerminalTab {
        let tab = TerminalTab(lastDirectory: directory)
        mutate {
            $0.terminalTabs = TerminalTabs.inserting(tab, into: $0.terminalTabs, after: $0.activeTerminalTabID)
            $0.activeTerminalTabID = tab.id
        }
        return tab
    }

    func selectTerminalTab(_ id: String) {
        guard config.terminalTabs.contains(where: { $0.id == id }) else { return }
        if config.activeTerminalTabID != id {
            mutate { $0.activeTerminalTabID = id }
        }
        DispatchQueue.main.async { self.tabRuntimes[id]?.focus() }
    }

    func selectTerminalTab(at index: Int) {
        guard config.terminalTabs.indices.contains(index) else { return }
        selectTerminalTab(config.terminalTabs[index].id)
    }

    func selectAdjacentTerminalTab(offset: Int) {
        guard let next = TerminalTabs.adjacent(to: config.activeTerminalTabID, by: offset, in: config.terminalTabs) else { return }
        selectTerminalTab(next)
    }

    func closeTerminalTab(_ id: String) {
        tabRuntimes.removeValue(forKey: id)?.terminate()
        let result = TerminalTabs.removing(id, from: config.terminalTabs, active: config.activeTerminalTabID)
        mutate {
            $0.terminalTabs = result.tabs
            $0.activeTerminalTabID = result.active
        }
        if let next = result.active {
            DispatchQueue.main.async { self.tabRuntimes[next]?.focus() }
        }
    }

    func closeOtherTerminalTabs(_ id: String) {
        for tab in config.terminalTabs where tab.id != id {
            tabRuntimes.removeValue(forKey: tab.id)?.terminate()
        }
        mutate {
            $0.terminalTabs = $0.terminalTabs.filter { $0.id == id }
            $0.activeTerminalTabID = id
        }
    }

    /// Nil, or a blank name, goes back to the automatic title.
    func renameTerminalTab(_ id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mutate { config in
            guard let index = config.terminalTabs.firstIndex(where: { $0.id == id }) else { return }
            config.terminalTabs[index].name = trimmed.isEmpty ? nil : trimmed
        }
    }

    func moveTerminalTab(_ id: String, onto targetID: String) {
        let next = TerminalTabs.moving(id, onto: targetID, in: config.terminalTabs)
        guard next != config.terminalTabs else { return }
        mutate { $0.terminalTabs = next }
    }

    func moveTerminalTab(_ id: String, by offset: Int) {
        guard let index = config.terminalTabs.firstIndex(where: { $0.id == id }),
              config.terminalTabs.indices.contains(index + offset) else { return }
        moveTerminalTab(id, onto: config.terminalTabs[index + offset].id)
    }

    func adjustTerminalFontSize(by delta: Double) {
        let next = min(max(terminalFontSize + delta, StudioConfig.minimumFontSize), StudioConfig.maximumFontSize)
        mutate { $0.terminalFontSize = next }
        for runtime in tabRuntimes.values { runtime.setFontSize(CGFloat(next)) }
    }

    func resetTerminalFontSize() {
        mutate { $0.terminalFontSize = nil }
        for runtime in tabRuntimes.values { runtime.setFontSize(CGFloat(config.fontSize)) }
    }

    /// The live shell behind a tab, spawned on first request in the folder
    /// the tab was last seen in, or at home.
    func terminalTabRuntime(for tab: TerminalTab) -> TerminalPaneRuntime {
        if let existing = tabRuntimes[tab.id] { return existing }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = tab.lastDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? home
        let runtime = TerminalPaneRuntime(
            id: tab.id,
            projectID: Self.terminalWorkspaceProjectID,
            projectRoot: directory,
            kind: .shell,
            launchCommand: nil,
            initialTitle: "Terminal",
            fontSize: CGFloat(terminalFontSize)
        )
        runtime.onCloseShortcut = { [weak self] runtime in
            self?.closeTerminalTab(runtime.id)
        }
        runtime.onTitleChange = { [weak self] _ in self?.bump() }
        runtime.onDirectoryChange = { [weak self] runtime in
            guard let self, let directory = runtime.currentDirectory else { return }
            self.mutate { config in
                guard let index = config.terminalTabs.firstIndex(where: { $0.id == runtime.id }),
                      config.terminalTabs[index].lastDirectory != directory else { return }
                config.terminalTabs[index].lastDirectory = directory
            }
        }
        runtime.onExit = { [weak self] _ in self?.bump() }
        tabRuntimes[tab.id] = runtime
        return runtime
    }

    func existingTerminalTabRuntime(_ id: String) -> TerminalPaneRuntime? {
        tabRuntimes[id]
    }

    /// Spawn every tab's shell, as iTerm restores all of its tabs at once,
    /// so switching between them is instant and each reopens in its folder.
    func warmTerminalTabs() {
        for tab in config.terminalTabs {
            let runtime = terminalTabRuntime(for: tab)
            guard !runtime.hasStarted else { continue }
            runtime.muteActivity(for: 8)
            _ = runtime.terminalView()
        }
    }

    /// Respawn every session so the app comes back where it was: shells at the
    /// project root, Claude conversations resumed.
    func reopenSessionsAtLaunchIfNeeded() {
        guard !reopenedAtLaunch else { return }
        reopenedAtLaunch = true
        prepareSidebarAtLaunch(projects: Supervisor.shared.projects)
        guard config.reopenSessionsAtLaunch else { return }
        // Only what the sidebar shows. An archived project keeps its sessions,
        // and they respawn the moment one is opened; waking an agent per
        // session of every project ever added is what made a launch slow once
        // the list grew.
        for session in config.sessions {
            guard !isArchived(session.projectID) || session.id == activeSessionID else { continue }
            for pane in session.panes {
                let runtime = self.runtime(for: pane, in: session)
                runtime.muteActivity(for: 20)
                _ = runtime.terminalView()
            }
        }
    }

    /// ⌘W closes the focused terminal instead of the window, iTerm-style. A
    /// local monitor sees the key before the menu bar does.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Server terminals are plain `TerminalView`s and need this too.
            if let terminal = event.window?.firstResponder as? TerminalView {
                TerminalOptionKey.prepare(terminal, for: event)
            }
            guard let view = event.window?.firstResponder as? StudioTerminalView else { return event }
            view.onKeyDown?()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command], event.charactersIgnoringModifiers == "w",
               let handler = view.onCloseShortcut, handler() {
                return nil
            }
            // ⌘1…⌘9 jump between the free terminal's tabs, as in a browser.
            if flags == [.command], let self, self.terminalWorkspaceVisible,
               let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                self.selectTerminalTab(at: digit - 1)
                return nil
            }
            // keyCode 36 is Return; ⇧↩ must not send the message.
            if flags == [.shift], event.keyCode == 36, let handler = view.onShiftReturn, handler() {
                return nil
            }
            return event
        }
    }

    // MARK: - Sessions

    func sessions(for projectID: String) -> [TerminalSession] {
        config.sessions.filter { $0.projectID == projectID }
    }

    func session(_ id: String) -> TerminalSession? {
        config.sessions.first { $0.id == id }
    }

    func project(for session: TerminalSession) -> Project? {
        Supervisor.shared.projects.first { $0.id == session.projectID }
    }

    @discardableResult
    func createSession(projectID: String, kind: PaneKind? = nil) -> TerminalSession {
        let existing = sessions(for: projectID).count
        let pane = makePane(kind: kind ?? defaultPaneKind)
        let session = TerminalSession(
            projectID: projectID,
            name: "Session \(existing + 1)",
            layout: .leaf(pane),
            focusedPaneID: pane.id
        )
        mutate {
            $0.sessions.append(session)
            $0.projectActivity[projectID] = Date()
        }
        return session
    }

    func renameSession(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func removeSession(_ id: String) {
        guard let session = session(id) else { return }
        for pane in session.panes {
            paneRuntimes.removeValue(forKey: pane.id)?.terminate()
        }
        mutate { $0.sessions.removeAll { $0.id == id } }
        if activeSessionID == id { activeSessionID = nil }
    }

    func removeSessions(inProject projectID: String) {
        for session in sessions(for: projectID) {
            removeSession(session.id)
        }
        quickRuntimes.removeValue(forKey: projectID)?.terminate()
        mutate {
            $0.projectActivity.removeValue(forKey: projectID)
            $0.archivedProjects.remove(projectID)
            $0.projectOrder.removeAll { $0 == projectID }
        }
    }

    // MARK: - Panes

    private var defaultPaneKind: PaneKind {
        config.launchAgentInNewPanes && config.agentLaunchCommand != nil ? .agent : .shell
    }

    private var presetUsesClaude: Bool {
        config.agentLaunchCommand?.hasPrefix("claude") == true
    }

    private func makePane(kind: PaneKind) -> TerminalPaneConfig {
        switch kind {
        case .agent:
            return TerminalPaneConfig(
                kind: .agent,
                launchCommand: config.agentLaunchCommand,
                title: config.defaultAgent.shortName,
                agentSessionID: presetUsesClaude ? UUID().uuidString.lowercased() : nil
            )
        case .shell:
            return TerminalPaneConfig(kind: .shell, launchCommand: nil, title: "Shell")
        }
    }

    func canAddPane(to sessionID: String) -> Bool {
        guard let session = session(sessionID) else { return false }
        return session.panes.count < config.maxPanesPerSession
    }

    /// Split the focused pane (or the given one). Returns the new pane's id.
    @discardableResult
    func split(sessionID: String, paneID: String? = nil, axis: SplitAxis, kind: PaneKind? = nil) -> String? {
        guard var session = session(sessionID), canAddPane(to: sessionID) else {
            NSSound.beep()
            return nil
        }
        let target = paneID ?? session.focusedPaneID ?? session.panes.last?.id
        guard let target, session.layout.contains(target) else { return nil }
        let pane = makePane(kind: kind ?? defaultPaneKind)
        session.layout = session.layout.splitting(target, axis: axis, adding: pane)
        session.focusedPaneID = pane.id
        session.zoomedPaneID = nil
        replace(session)
        return pane.id
    }

    func closePane(sessionID: String, paneID: String) {
        guard var session = session(sessionID) else { return }
        paneRuntimes.removeValue(forKey: paneID)?.terminate()
        guard let layout = session.layout.removing(paneID) else {
            removeSession(sessionID)
            if let project = Supervisor.shared.projects.first(where: { $0.id == session.projectID }) {
                pendingSelection = .project(project.id)
            }
            return
        }
        session.layout = layout
        if session.zoomedPaneID == paneID { session.zoomedPaneID = nil }
        if session.focusedPaneID == paneID || session.focusedPaneID == nil {
            session.focusedPaneID = layout.paneIDs.first
        }
        replace(session)
        if let next = session.focusedPaneID {
            DispatchQueue.main.async { self.paneRuntimes[next]?.focus() }
        }
    }

    func focusPane(sessionID: String, paneID: String) {
        guard let session = session(sessionID), session.focusedPaneID != paneID else { return }
        update(sessionID) { $0.focusedPaneID = paneID }
        for pane in session.panes where pane.id != paneID {
            paneRuntimes[pane.id]?.markUnfocused()
        }
    }

    func focusAdjacent(sessionID: String, offset: Int) {
        guard let session = session(sessionID) else { return }
        let ids = session.layout.paneIDs
        guard ids.count > 1 else { return }
        let current = ids.firstIndex(of: session.focusedPaneID ?? "") ?? 0
        let next = ids[(current + offset + ids.count) % ids.count]
        update(sessionID) {
            $0.focusedPaneID = next
            if $0.zoomedPaneID != nil { $0.zoomedPaneID = next }
        }
        paneRuntimes[next]?.focus()
    }

    func toggleZoom(sessionID: String, paneID: String? = nil) {
        guard let session = session(sessionID) else { return }
        let target = paneID ?? session.focusedPaneID
        update(sessionID) {
            if $0.zoomedPaneID != nil, paneID == nil || $0.zoomedPaneID == paneID {
                $0.zoomedPaneID = nil
            } else {
                $0.zoomedPaneID = target
                if let target { $0.focusedPaneID = target }
            }
        }
        if let target { DispatchQueue.main.async { self.paneRuntimes[target]?.focus() } }
    }

    func setRatio(sessionID: String, splitID: String, ratio: Double) {
        update(sessionID) {
            $0.layout = $0.layout.updatingRatio(splitID: splitID, ratio: min(max(ratio, 0.15), 0.85))
        }
    }

    // MARK: - Text size

    func fontSize(for session: TerminalSession) -> Double {
        session.fontSize ?? config.fontSize
    }

    func adjustFontSize(sessionID: String, by delta: Double) {
        guard let session = session(sessionID) else { return }
        let next = min(max(fontSize(for: session) + delta, StudioConfig.minimumFontSize), StudioConfig.maximumFontSize)
        update(sessionID) { $0.fontSize = next }
        applyFontSize(next, to: session)
    }

    func resetFontSize(sessionID: String) {
        guard let session = session(sessionID) else { return }
        update(sessionID) { $0.fontSize = nil }
        applyFontSize(config.fontSize, to: session)
    }

    private func applyFontSize(_ size: Double, to session: TerminalSession) {
        for pane in session.panes {
            paneRuntimes[pane.id]?.setFontSize(CGFloat(size))
        }
    }

    // MARK: - Runtimes

    /// The command a pane types on start: the preset, plus Claude's session id
    /// so a conversation survives an app relaunch.
    private func effectiveLaunchCommand(for pane: TerminalPaneConfig, projectRoot: String) -> String? {
        guard let base = pane.launchCommand else { return nil }
        guard let sessionID = pane.agentSessionID else { return base }
        let hasTranscript = ClaudeTranscripts.transcriptExists(sessionID: sessionID, projectRoot: projectRoot)
        return ClaudeTranscripts.launchCommand(
            base: base,
            sessionID: sessionID,
            hasTranscript: hasTranscript,
            resumeNote: hasTranscript ? ResumeNotes.take(sessionID: sessionID) : nil
        )
    }

    /// Start over in one pane: a fresh shell, and a fresh conversation id.
    func resetPane(sessionID: String, paneID: String) {
        guard let session = session(sessionID), var pane = session.layout.pane(paneID) else { return }
        if pane.agentSessionID != nil {
            pane.agentSessionID = UUID().uuidString.lowercased()
            let newID = pane.agentSessionID
            update(sessionID) {
                $0.layout = $0.layout.updatingPane(paneID) { $0.agentSessionID = newID }
            }
        }
        let root = project(for: session).map { NSString(string: $0.root).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let command = effectiveLaunchCommand(for: pane, projectRoot: root)
        if let runtime = paneRuntimes[paneID] {
            runtime.reset(launchCommand: command)
        }
    }

    /// The live shell for a pane, spawned on first request.
    func runtime(for pane: TerminalPaneConfig, in session: TerminalSession) -> TerminalPaneRuntime {
        if let existing = paneRuntimes[pane.id] { return existing }
        let root = project(for: session).map { NSString(string: $0.root).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let runtime = TerminalPaneRuntime(
            id: pane.id,
            projectID: session.projectID,
            projectRoot: root,
            kind: pane.kind,
            launchCommand: effectiveLaunchCommand(for: pane, projectRoot: root),
            initialTitle: pane.title ?? (pane.kind == .agent ? config.defaultAgent.shortName : "Shell"),
            fontSize: CGFloat(fontSize(for: session))
        )
        let sessionID = session.id
        runtime.onFocus = { [weak self] runtime in
            self?.focusPane(sessionID: sessionID, paneID: runtime.id)
        }
        runtime.onCloseShortcut = { [weak self] runtime in
            self?.closePane(sessionID: sessionID, paneID: runtime.id)
        }
        runtime.onTitleChange = { [weak self] runtime in
            guard let self else { return }
            self.update(sessionID) {
                $0.layout = $0.layout.updatingPane(runtime.id) { $0.title = runtime.title }
            }
        }
        runtime.onExit = { [weak self] _ in
            self?.bump()
        }
        paneRuntimes[pane.id] = runtime
        return runtime
    }

    func existingRuntime(paneID: String) -> TerminalPaneRuntime? {
        paneRuntimes[paneID]
    }

    func focusedRuntime(sessionID: String) -> TerminalPaneRuntime? {
        guard let session = session(sessionID), let id = session.focusedPaneID else { return nil }
        return paneRuntimes[id]
    }

    /// True when any pane of the session has a live shell.
    func isLive(_ session: TerminalSession) -> Bool {
        session.panes.contains { paneRuntimes[$0.id]?.isRunning == true }
    }

    /// One scratch shell per project, kept while the app runs.
    func quickTerminal(for project: Project) -> TerminalPaneRuntime {
        if let existing = quickRuntimes[project.id] { return existing }
        let runtime = TerminalPaneRuntime(
            id: "quick_" + project.id,
            projectID: project.id,
            projectRoot: NSString(string: project.root).expandingTildeInPath,
            kind: .shell,
            launchCommand: nil,
            initialTitle: "Quick terminal",
            fontSize: CGFloat(config.fontSize)
        )
        quickRuntimes[project.id] = runtime
        return runtime
    }

    func setQuickTerminalSize(_ size: CGSize) {
        mutate { $0.quickTerminalSize = size }
    }

    func setEnvPanelSize(_ size: CGSize) {
        mutate { $0.envPanelSize = size }
    }

    /// The two floating panels share the top-right corner, so one at a time.
    func toggleQuickTerminal() {
        guard activeProjectID != nil else { NSSound.beep(); return }
        if quickTerminalVisible {
            quickTerminalVisible = false
        } else {
            envPanelProjectID = nil
            quickTerminalVisible = true
        }
    }

    func toggleEnvPanel(projectID: String) {
        if envPanelProjectID == projectID {
            envPanelProjectID = nil
        } else {
            quickTerminalVisible = false
            envPanelProjectID = projectID
        }
    }

    /// Type text into the focused pane of the active session (or the quick
    /// terminal when it is showing), without pressing Return.
    func insertIntoFocusedTerminal(_ text: String) {
        if quickTerminalVisible, let projectID = activeProjectID, let runtime = quickRuntimes[projectID] {
            runtime.send(text: text)
            runtime.focus()
            return
        }
        guard let sessionID = activeSessionID, let runtime = focusedRuntime(sessionID: sessionID) else {
            NSSound.beep()
            return
        }
        runtime.send(text: text)
        runtime.focus()
    }

    // MARK: - Settings

    func updateSettings(_ change: (inout StudioConfig) -> Void) {
        let previousFont = config.fontSize
        mutate(change)
        if config.fontSize != previousFont {
            for session in config.sessions where session.fontSize == nil {
                applyFontSize(config.fontSize, to: session)
            }
            for runtime in quickRuntimes.values {
                runtime.setFontSize(CGFloat(config.fontSize))
            }
            if config.terminalFontSize == nil {
                for runtime in tabRuntimes.values {
                    runtime.setFontSize(CGFloat(config.fontSize))
                }
            }
        }
    }

    // MARK: - Commands

    func perform(_ command: StudioCommand) {
        if terminalWorkspaceVisible, performInTerminalWorkspace(command) { return }
        switch command {
        case .newSession:
            guard let projectID = activeProjectID else { NSSound.beep(); return }
            let session = createSession(projectID: projectID)
            pendingSelection = .session(session.id)
        case .newPane(let kind):
            guard let sessionID = activeSessionID else { NSSound.beep(); return }
            split(sessionID: sessionID, axis: .horizontal, kind: kind)
        case .splitRight:
            guard let sessionID = activeSessionID else { NSSound.beep(); return }
            split(sessionID: sessionID, axis: .horizontal)
        case .splitDown:
            guard let sessionID = activeSessionID else { NSSound.beep(); return }
            split(sessionID: sessionID, axis: .vertical)
        case .closePane:
            guard let sessionID = activeSessionID, let paneID = session(sessionID)?.focusedPaneID else {
                NSSound.beep()
                return
            }
            closePane(sessionID: sessionID, paneID: paneID)
        case .toggleZoom:
            guard let sessionID = activeSessionID else { return }
            toggleZoom(sessionID: sessionID)
        case .focusNext:
            guard let sessionID = activeSessionID else { return }
            focusAdjacent(sessionID: sessionID, offset: 1)
        case .focusPrevious:
            guard let sessionID = activeSessionID else { return }
            focusAdjacent(sessionID: sessionID, offset: -1)
        case .biggerText:
            guard let sessionID = activeSessionID else { return }
            adjustFontSize(sessionID: sessionID, by: 1)
        case .smallerText:
            guard let sessionID = activeSessionID else { return }
            adjustFontSize(sessionID: sessionID, by: -1)
        case .resetText:
            guard let sessionID = activeSessionID else { return }
            resetFontSize(sessionID: sessionID)
        case .toggleQuickTerminal:
            toggleQuickTerminal()
        case .editEnvironment:
            guard let projectID = activeProjectID else { NSSound.beep(); return }
            toggleEnvPanel(projectID: projectID)
        case .clearTerminal:
            if quickTerminalVisible, let projectID = activeProjectID, let runtime = quickRuntimes[projectID] {
                runtime.clear()
            } else if let sessionID = activeSessionID {
                focusedRuntime(sessionID: sessionID)?.clear()
            }
        }
    }

    /// The same shortcuts, read as a browser reads them while the free
    /// terminal is on screen: tabs instead of panes. False hands the command
    /// back to the session logic.
    private func performInTerminalWorkspace(_ command: StudioCommand) -> Bool {
        switch command {
        case .newPane:
            createTerminalTab()
        case .closePane:
            guard let tab = activeTerminalTab else { NSSound.beep(); return true }
            closeTerminalTab(tab.id)
        case .focusNext:
            selectAdjacentTerminalTab(offset: 1)
        case .focusPrevious:
            selectAdjacentTerminalTab(offset: -1)
        case .biggerText:
            adjustTerminalFontSize(by: 1)
        case .smallerText:
            adjustTerminalFontSize(by: -1)
        case .resetText:
            resetTerminalFontSize()
        case .clearTerminal:
            guard let tab = activeTerminalTab else { return true }
            tabRuntimes[tab.id]?.clear()
        case .splitRight, .splitDown, .toggleZoom:
            NSSound.beep()
        case .newSession, .toggleQuickTerminal, .editEnvironment:
            return false
        }
        return true
    }

    // MARK: - Lifecycle

    /// Called on quit: every shell goes down with the app.
    func terminateEverything() {
        store.saveNow()
        for runtime in paneRuntimes.values { runtime.terminate() }
        for runtime in quickRuntimes.values { runtime.terminate() }
        for runtime in tabRuntimes.values { runtime.terminate() }
    }

    // MARK: - Mutation helpers

    private func mutate(_ change: (inout StudioConfig) -> Void) {
        store.mutate(change)
        config = store.config
    }

    private func update(_ sessionID: String, _ change: (inout TerminalSession) -> Void) {
        mutate { config in
            guard let index = config.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            change(&config.sessions[index])
        }
    }

    private func replace(_ session: TerminalSession) {
        mutate { config in
            guard let index = config.sessions.firstIndex(where: { $0.id == session.id }) else { return }
            config.sessions[index] = session
        }
    }

    private func bump() {
        revision &+= 1
    }
}
