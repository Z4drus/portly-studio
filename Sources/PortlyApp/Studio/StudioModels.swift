import Foundation

// MARK: - Terminal sessions (what lives in ~/.config/portly/studio.json)

/// What a pane runs on top of the login shell.
enum PaneKind: String, Codable, Hashable {
    /// A coding agent (Claude Code, Codex…) launched from the default preset.
    case agent
    /// A plain interactive shell.
    case shell
}

struct TerminalPaneConfig: Codable, Identifiable, Hashable {
    var id: String
    var kind: PaneKind
    /// Command typed into the shell right after it starts. Nil keeps a bare shell.
    var launchCommand: String?
    /// Last title reported by the process (OSC 0/2), kept so a restored session
    /// reads the same before its shells are respawned.
    var title: String?
    /// Claude Code conversation id for this pane, so a relaunch resumes the
    /// same chat (`--resume`) instead of starting over.
    var agentSessionID: String?

    init(
        id: String = TerminalPaneConfig.newID(),
        kind: PaneKind,
        launchCommand: String? = nil,
        title: String? = nil,
        agentSessionID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.launchCommand = launchCommand
        self.title = title
        self.agentSessionID = agentSessionID
    }

    static func newID() -> String { "pane_" + String(UUID().uuidString.prefix(8)).lowercased() }
}

enum SplitAxis: String, Codable, Hashable {
    /// Panes side by side (a vertical divider).
    case horizontal
    /// Panes stacked (a horizontal divider).
    case vertical
}

/// A binary split tree. Small enough that every operation is a plain recursion.
indirect enum PaneLayout: Codable, Hashable {
    case leaf(TerminalPaneConfig)
    case split(id: String, axis: SplitAxis, ratio: Double, first: PaneLayout, second: PaneLayout)

    static func newSplitID() -> String { "split_" + String(UUID().uuidString.prefix(8)).lowercased() }

    var panes: [TerminalPaneConfig] {
        switch self {
        case .leaf(let pane): return [pane]
        case .split(_, _, _, let first, let second): return first.panes + second.panes
        }
    }

    var paneIDs: [String] { panes.map(\.id) }

    func pane(_ id: String) -> TerminalPaneConfig? {
        panes.first { $0.id == id }
    }

    func contains(_ id: String) -> Bool {
        paneIDs.contains(id)
    }

    /// Replace the leaf `paneID` with a split holding it and `newPane`.
    func splitting(_ paneID: String, axis: SplitAxis, adding newPane: TerminalPaneConfig) -> PaneLayout {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return self }
            return .split(id: PaneLayout.newSplitID(), axis: axis, ratio: 0.5, first: .leaf(pane), second: .leaf(newPane))
        case .split(let id, let splitAxis, let ratio, let first, let second):
            return .split(
                id: id,
                axis: splitAxis,
                ratio: ratio,
                first: first.splitting(paneID, axis: axis, adding: newPane),
                second: second.splitting(paneID, axis: axis, adding: newPane)
            )
        }
    }

    /// Remove a leaf; a split left with a single child collapses into it.
    /// Returns nil when the tree becomes empty.
    func removing(_ paneID: String) -> PaneLayout? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            let newFirst = first.removing(paneID)
            let newSecond = second.removing(paneID)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let f?, let s?): return .split(id: id, axis: axis, ratio: ratio, first: f, second: s)
            }
        }
    }

    func updatingRatio(splitID: String, ratio newRatio: Double) -> PaneLayout {
        switch self {
        case .leaf: return self
        case .split(let id, let axis, let ratio, let first, let second):
            if id == splitID {
                return .split(id: id, axis: axis, ratio: newRatio, first: first, second: second)
            }
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: first.updatingRatio(splitID: splitID, ratio: newRatio),
                second: second.updatingRatio(splitID: splitID, ratio: newRatio)
            )
        }
    }

    func updatingPane(_ paneID: String, _ change: (inout TerminalPaneConfig) -> Void) -> PaneLayout {
        switch self {
        case .leaf(var pane):
            guard pane.id == paneID else { return self }
            change(&pane)
            return .leaf(pane)
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: first.updatingPane(paneID, change),
                second: second.updatingPane(paneID, change)
            )
        }
    }
}

struct TerminalSession: Codable, Identifiable, Hashable {
    var id: String
    var projectID: String
    var name: String
    var createdAt: Date
    var layout: PaneLayout
    var focusedPaneID: String?
    var zoomedPaneID: String?
    /// Per-session text size. Nil follows the global default.
    var fontSize: Double?

    init(
        id: String = TerminalSession.newID(),
        projectID: String,
        name: String,
        createdAt: Date = Date(),
        layout: PaneLayout,
        focusedPaneID: String? = nil,
        zoomedPaneID: String? = nil,
        fontSize: Double? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.createdAt = createdAt
        self.layout = layout
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
        self.fontSize = fontSize
    }

    static func newID() -> String { "ses_" + String(UUID().uuidString.prefix(8)).lowercased() }

    var panes: [TerminalPaneConfig] { layout.panes }
}

// MARK: - Agent presets

/// The coding CLI a fresh terminal starts with.
enum AgentPreset: String, Codable, CaseIterable, Identifiable {
    case claudeBypass
    case claude
    case codexFullAuto
    case codex
    case cursorAgent
    case gemini
    case custom
    case shell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeBypass: return "Claude Code · bypass permissions"
        case .claude: return "Claude Code"
        case .codexFullAuto: return "Codex · full auto"
        case .codex: return "Codex"
        case .cursorAgent: return "Cursor Agent"
        case .gemini: return "Gemini CLI"
        case .custom: return "Custom command"
        case .shell: return "Plain shell"
        }
    }

    /// Short name for pane titles before the process reports its own.
    var shortName: String {
        switch self {
        case .claudeBypass, .claude: return "Claude Code"
        case .codexFullAuto, .codex: return "Codex"
        case .cursorAgent: return "Cursor Agent"
        case .gemini: return "Gemini"
        case .custom: return "Agent"
        case .shell: return "Shell"
        }
    }

    /// Nil means "no launch command", a bare shell.
    func command(custom: String) -> String? {
        switch self {
        case .claudeBypass: return "claude --dangerously-skip-permissions"
        case .claude: return "claude"
        case .codexFullAuto: return "codex --full-auto"
        case .codex: return "codex"
        case .cursorAgent: return "cursor-agent"
        case .gemini: return "gemini"
        case .custom:
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .shell: return nil
        }
    }

    var iconID: String {
        switch self {
        case .claudeBypass, .claude: return AppIcon.claude.rawValue
        case .codexFullAuto, .codex: return AppIcon.aiDeveloper.rawValue
        case .cursorAgent: return AppIcon.magicWand.rawValue
        case .gemini: return AppIcon.sparkle.rawValue
        case .custom: return AppIcon.robot.rawValue
        case .shell: return AppIcon.terminal.rawValue
        }
    }
}

// MARK: - Studio configuration

struct StudioConfig: Codable {
    var version: Int
    var defaultAgent: AgentPreset
    var customAgentCommand: String
    /// When on, every new pane starts the default agent; off gives bare shells.
    var launchAgentInNewPanes: Bool
    var fontSize: Double
    var maxPanesPerSession: Int
    var quickTerminalSize: CGSize
    var envPanelSize: CGSize
    /// Respawn every session's shells at launch and resume their agents, so
    /// the app comes back exactly where it was.
    var reopenSessionsAtLaunch: Bool
    /// Pre-approve a new project's folder in Claude Code, so its workspace trust
    /// dialog never interrupts the first agent terminal opened there.
    var trustNewProjectsInClaudeCode: Bool
    var sessions: [TerminalSession]

    static let defaultFontSize: Double = 13
    static let minimumFontSize: Double = 9
    static let maximumFontSize: Double = 28

    init(
        version: Int = 1,
        defaultAgent: AgentPreset = .claudeBypass,
        customAgentCommand: String = "",
        launchAgentInNewPanes: Bool = true,
        fontSize: Double = StudioConfig.defaultFontSize,
        maxPanesPerSession: Int = 5,
        quickTerminalSize: CGSize = CGSize(width: 560, height: 360),
        envPanelSize: CGSize = CGSize(width: 760, height: 520),
        reopenSessionsAtLaunch: Bool = true,
        trustNewProjectsInClaudeCode: Bool = true,
        sessions: [TerminalSession] = []
    ) {
        self.version = version
        self.defaultAgent = defaultAgent
        self.customAgentCommand = customAgentCommand
        self.launchAgentInNewPanes = launchAgentInNewPanes
        self.fontSize = fontSize
        self.maxPanesPerSession = maxPanesPerSession
        self.quickTerminalSize = quickTerminalSize
        self.envPanelSize = envPanelSize
        self.reopenSessionsAtLaunch = reopenSessionsAtLaunch
        self.trustNewProjectsInClaudeCode = trustNewProjectsInClaudeCode
        self.sessions = sessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        defaultAgent = try c.decodeIfPresent(AgentPreset.self, forKey: .defaultAgent) ?? .claudeBypass
        customAgentCommand = try c.decodeIfPresent(String.self, forKey: .customAgentCommand) ?? ""
        launchAgentInNewPanes = try c.decodeIfPresent(Bool.self, forKey: .launchAgentInNewPanes) ?? true
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? StudioConfig.defaultFontSize
        maxPanesPerSession = try c.decodeIfPresent(Int.self, forKey: .maxPanesPerSession) ?? 5
        quickTerminalSize = try c.decodeIfPresent(CGSize.self, forKey: .quickTerminalSize) ?? CGSize(width: 560, height: 360)
        envPanelSize = try c.decodeIfPresent(CGSize.self, forKey: .envPanelSize) ?? CGSize(width: 760, height: 520)
        reopenSessionsAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .reopenSessionsAtLaunch) ?? true
        trustNewProjectsInClaudeCode = try c.decodeIfPresent(Bool.self, forKey: .trustNewProjectsInClaudeCode) ?? true
        sessions = try c.decodeIfPresent([TerminalSession].self, forKey: .sessions) ?? []
    }

    /// The command a new agent pane types, or nil for a bare shell.
    var agentLaunchCommand: String? {
        defaultAgent.command(custom: customAgentCommand)
    }
}

/// Reads and writes `~/.config/portly/studio.json`, beside Portly's own config
/// so the CLI and agents never see terminal-session state in `config.json`.
final class StudioStore {
    private(set) var config: StudioConfig
    private let url: URL
    private var pendingSave: DispatchWorkItem?

    init(url: URL = StudioStore.defaultURL) {
        self.url = url
        config = StudioStore.read(from: url) ?? StudioConfig()
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("portly", isDirectory: true)
            .appendingPathComponent("studio.json")
    }

    static func read(from url: URL) -> StudioConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StudioConfig.self, from: data)
    }

    func mutate(_ block: (inout StudioConfig) -> Void) {
        block(&config)
        scheduleSave()
    }

    /// Divider drags mutate dozens of times per second; coalesce the writes.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(config) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}


// MARK: - Claude Code transcripts

/// Where Claude Code keeps conversations: `~/.claude/projects/<encoded cwd>/<id>.jsonl`.
enum ClaudeTranscripts {
    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// `/Users/me/Documents/app` becomes `-Users-me-Documents-app`.
    static func encodedDirectoryName(forProjectRoot root: String) -> String {
        let expanded = NSString(string: root).expandingTildeInPath
        return expanded.replacingOccurrences(of: "/", with: "-")
    }

    static func transcriptExists(sessionID: String, projectRoot: String) -> Bool {
        let fm = FileManager.default
        let direct = projectsDirectory
            .appendingPathComponent(encodedDirectoryName(forProjectRoot: projectRoot), isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        if fm.fileExists(atPath: direct.path) { return true }
        // The encoding has changed across versions; a shallow scan catches it.
        guard let directories = try? fm.contentsOfDirectory(atPath: projectsDirectory.path) else { return false }
        return directories.contains { directory in
            fm.fileExists(atPath: projectsDirectory.appendingPathComponent(directory).appendingPathComponent("\(sessionID).jsonl").path)
        }
    }

    /// The command that starts or resumes the pane's Claude conversation.
    static func launchCommand(base: String, sessionID: String?, hasTranscript: Bool) -> String {
        guard let sessionID, base.hasPrefix("claude") else { return base }
        return hasTranscript ? "\(base) --resume \(sessionID)" : "\(base) --session-id \(sessionID)"
    }
}
