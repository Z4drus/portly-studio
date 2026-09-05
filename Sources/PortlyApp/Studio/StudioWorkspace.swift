import AppKit
import Foundation
import PortlyCore
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
    private var reopenedAtLaunch = false

    private let store: StudioStore
    private var paneRuntimes: [String: TerminalPaneRuntime] = [:]
    private var quickRuntimes: [String: TerminalPaneRuntime] = [:]

    private var keyMonitor: Any?
    private var activityTicker: Timer?

    private init(store: StudioStore = StudioStore()) {
        self.store = store
        config = store.config
        installKeyMonitor()
        startActivityTicker()
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
        for (id, runtime) in paneRuntimes {
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
        }
        for id in next.keys where paneRuntimes[id] == nil {
            next.removeValue(forKey: id)
            changed = true
        }
        if changed { paneActivity = next }
    }

    private func isOnScreen(paneID: String) -> Bool {
        guard let sessionID = activeSessionID, let session = session(sessionID) else { return false }
        return session.layout.contains(paneID) && NSApp.isActive
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
    func workingPaneCount(now: Date = Date()) -> Int {
        let all = Array(paneRuntimes.values) + Array(quickRuntimes.values)
        return all.filter { $0.isProducingOutput(within: KeepAwake.workingWindow, now: now) }.count
    }

    /// Respawn every session so the app comes back where it was: shells at the
    /// project root, Claude conversations resumed.
    func reopenSessionsAtLaunchIfNeeded() {
        guard !reopenedAtLaunch else { return }
        reopenedAtLaunch = true
        guard config.reopenSessionsAtLaunch else { return }
        for session in config.sessions {
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let view = event.window?.firstResponder as? StudioTerminalView else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command], event.charactersIgnoringModifiers == "w",
               let handler = view.onCloseShortcut, handler() {
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
        mutate { $0.sessions.append(session) }
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
        return ClaudeTranscripts.launchCommand(base: base, sessionID: sessionID, hasTranscript: hasTranscript)
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
        }
    }

    // MARK: - Commands

    func perform(_ command: StudioCommand) {
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

    // MARK: - Lifecycle

    /// Called on quit: every shell goes down with the app.
    func terminateEverything() {
        store.saveNow()
        for runtime in paneRuntimes.values { runtime.terminate() }
        for runtime in quickRuntimes.values { runtime.terminate() }
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
