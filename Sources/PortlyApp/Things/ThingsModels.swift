import Foundation

// MARK: - Things

/// A Things area: the list of to-dos the panel follows.
struct ThingsArea: Identifiable, Equatable {
    let id: String
    let title: String
}

/// One open to-do of the followed area, as the Things database holds it.
struct ThingsTask: Identifiable, Equatable {
    let id: String
    let title: String
    let notes: String
    /// The Things project it sits in, when it is not directly in the area.
    let projectTitle: String?
    let deadline: DateComponents?
    /// Things' own order: the area's loose to-dos first, then each project's.
    let order: Int
}

/// Things packs a calendar date into one integer: `YYYYYYYYYYYMMMMDDDDD0000000`.
enum ThingsDate {
    static func components(packed value: Int) -> DateComponents? {
        guard value > 0 else { return nil }
        let year = value >> 16
        let month = (value >> 12) & 0xF
        let day = (value >> 7) & 0x1F
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    static func packed(year: Int, month: Int, day: Int) -> Int {
        (year << 16) | (month << 12) | (day << 7)
    }
}

// MARK: - Branches

/// What a Claude Code session reports about itself in `~/.claude/sessions`.
enum AgentStatus: Equatable {
    case busy
    /// Blocked on you: a permission prompt or a question.
    case waiting
    case idle
    /// No Claude Code process in the terminal any more.
    case gone
}

/// A piece of a Things to-do handed to an agent in one Portly terminal.
struct ThingsBranch: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        /// The agent is on it.
        case working
        /// The agent stopped to ask you something.
        case waiting
        /// The agent finished: its work is waiting for your review.
        case review
        /// You reviewed it. Shown struck through until you remove it.
        case done
    }

    var id: String
    /// The Things to-do this work belongs to.
    var taskID: String
    /// A few vague words, never the prompt itself.
    var label: String
    /// The Portly terminal the agent runs in: a session pane or a free-terminal tab.
    var paneID: String
    var state: State
    var createdAt: Date
    var updatedAt: Date

    /// Still followed: a terminal with an active branch is not sorted again.
    var isActive: Bool { state != .done }

    /// Where an agent's report moves the branch. Only you mark it done, and
    /// a branch you closed stays closed: new work in that terminal is sorted
    /// again rather than reopening it.
    static func next(_ state: State, status: AgentStatus) -> State {
        switch (state, status) {
        case (.done, _): return .done
        case (_, .busy): return .working
        case (_, .waiting): return .waiting
        case (.working, .idle), (.working, .gone), (.waiting, .idle), (.waiting, .gone): return .review
        case (.review, _): return .review
        }
    }
}

/// A prompt waiting for the sorting agent, shown at the top of the panel.
struct TriageJob: Identifiable, Equatable {
    /// Reused as the branch id when the prompt matches a to-do, so the row
    /// travels from the top of the panel to its place under the to-do.
    let id: String
    let paneID: String
    let excerpt: String
}

/// What the panel remembers across launches, in `~/.config/portly/things.json`.
struct ThingsPanelState: Codable, Equatable {
    var areaID: String?
    var autoSort = true
    var branches: [ThingsBranch] = []
    /// The last prompt seen in each terminal, so a relaunch never sorts it again.
    var seenPrompts: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        areaID = try container.decodeIfPresent(String.self, forKey: .areaID)
        autoSort = try container.decodeIfPresent(Bool.self, forKey: .autoSort) ?? true
        branches = try container.decodeIfPresent([ThingsBranch].self, forKey: .branches) ?? []
        seenPrompts = try container.decodeIfPresent([String: String].self, forKey: .seenPrompts) ?? [:]
    }

    /// Quitting Portly ends every agent it runs: what was working at the
    /// time stopped, and is now yours to look at.
    mutating func settleAfterLaunch() {
        for index in branches.indices where branches[index].state == .working || branches[index].state == .waiting {
            branches[index].state = .review
        }
    }
}

// MARK: - Board

/// The panel's order: to-dos with work in progress first, newest work on
/// top, then every other to-do in Things' own order.
enum ThingsBoard {
    struct Row: Identifiable, Equatable {
        let task: ThingsTask
        let branches: [ThingsBranch]
        var id: String { task.id }

        var workingCount: Int { branches.filter { $0.state == .working }.count }
        var needsYouCount: Int { branches.filter { $0.state == .review || $0.state == .waiting }.count }
    }

    static func rows(tasks: [ThingsTask], branches: [ThingsBranch]) -> [Row] {
        let byTask = Dictionary(grouping: branches, by: \.taskID)
        let rows = tasks.map { task in
            Row(task: task, branches: (byTask[task.id] ?? []).sorted { $0.createdAt < $1.createdAt })
        }
        let started = rows
            .filter { !$0.branches.isEmpty }
            .sorted { lhs, rhs in
                let left = lhs.branches.map(\.createdAt).max() ?? .distantPast
                let right = rhs.branches.map(\.createdAt).max() ?? .distantPast
                return left == right ? lhs.task.order < rhs.task.order : left > right
            }
        return started + rows.filter { $0.branches.isEmpty }
    }

    /// One short line for the pending row: the start of the prompt, without
    /// the markup Claude Code wraps pasted text in.
    static func excerpt(of prompt: String, limit: Int = 90) -> String {
        let withoutTags = prompt.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = withoutTags
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
