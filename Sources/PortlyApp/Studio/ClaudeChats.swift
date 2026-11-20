import Foundation

// MARK: - Past chats

/// One past Claude Code conversation of a project, as its transcript tells it.
struct ClaudeChat: Identifiable, Equatable, Sendable {
    /// The conversation id: the transcript's file name, what `--resume` takes.
    let id: String
    /// The name you gave it (`/rename`), else the one Claude Code gave it, the
    /// title a pane header shows while it runs.
    let title: String
    /// The last thing you asked in it, when the transcript says.
    let lastPrompt: String?
    /// When somebody last spoke in it.
    let lastExchange: Date
}

/// What the head and tail of a transcript say about a conversation. Every
/// field is optional: Claude Code writes these entries on its own schedule.
struct TranscriptSummary: Equatable {
    /// `/rename`, the newest one.
    var customTitle: String?
    /// The title Claude Code generates and puts in the terminal title.
    var aiTitle: String?
    var lastPrompt: String?
    var lastExchange: Date?
    /// The first thing you typed, for a conversation that never got a title.
    var firstPrompt: String?

    var title: String? { customTitle ?? aiTitle ?? firstPrompt }

    private static let customTitleMarker = Data(#""type":"custom-title""#.utf8)
    private static let aiTitleMarker = Data(#""type":"ai-title""#.utf8)
    private static let lastPromptMarker = Data(#""type":"last-prompt""#.utf8)
    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    /// The newest of each entry in the tail of a transcript, read from the
    /// end. The first line of a tail read mid-file is partial and skipped.
    static func reading(tail data: Data, isWholeFile: Bool) -> TranscriptSummary {
        var summary = TranscriptSummary()
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            if summary.customTitle == nil, line.range(of: customTitleMarker) != nil {
                summary.customTitle = text(in: line, keys: ["customTitle", "title"])
            } else if summary.aiTitle == nil, line.range(of: aiTitleMarker) != nil {
                summary.aiTitle = text(in: line, keys: ["aiTitle", "title"])
            } else if summary.lastPrompt == nil, line.range(of: lastPromptMarker) != nil {
                summary.lastPrompt = text(in: line, keys: ["lastPrompt"])
            } else if summary.lastExchange == nil,
                      line.range(of: userMarker) != nil || line.range(of: assistantMarker) != nil {
                summary.lastExchange = ClaudeTranscripts.lastExchange(inTail: Data(line), isWholeFile: true)
            }
            if summary.customTitle != nil, summary.aiTitle != nil,
               summary.lastPrompt != nil, summary.lastExchange != nil { break }
        }
        return summary
    }

    /// A title from the start of the transcript, for when the tail had
    /// none: the first title Claude Code wrote, else the first prompt.
    mutating func fill(fromHead data: Data) {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A head read that stopped mid-line ends on a partial one.
        if data.last != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeLast() }
        for line in lines {
            if customTitle == nil, line.range(of: Self.customTitleMarker) != nil {
                customTitle = Self.text(in: line, keys: ["customTitle", "title"])
            } else if aiTitle == nil, line.range(of: Self.aiTitleMarker) != nil {
                aiTitle = Self.text(in: line, keys: ["aiTitle", "title"])
            } else if firstPrompt == nil, line.range(of: Self.userMarker) != nil {
                firstPrompt = Self.prompt(in: line)
            }
            if aiTitle != nil || customTitle != nil { return }
        }
    }

    /// A top-level string field, on one line and bounded.
    private static func text(in line: Data.SubSequence, keys: [String]) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        for key in keys {
            if let value = object[key] as? String, let cleaned = ClaudeChats.oneLine(value) { return cleaned }
        }
        return nil
    }

    /// What you typed in a user entry. Tool results, Claude Code's own
    /// notes (`isMeta`) and wrapped commands (`<command-name>…`) are not.
    private static func prompt(in line: Data.SubSequence) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "user",
              object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return nil }
        var text: String?
        if let content = message["content"] as? String {
            text = content
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let text, !text.trimmingCharacters(in: .whitespaces).hasPrefix("<") else { return nil }
        return ClaudeChats.oneLine(text)
    }
}

/// Reads the conversations Claude Code keeps for a folder, in
/// `~/.claude/projects/<encoded folder>/<id>.jsonl`.
enum ClaudeChats {
    static let maximumTitleLength = 140

    /// Every conversation started at the project root, newest first. Only
    /// the head and the tail of each transcript are read. A conversation
    /// nobody spoke in (a terminal opened and closed) is left out.
    static func list(projectRoot: String) -> [ClaudeChat] {
        let fm = FileManager.default
        var seen = Set<String>()
        var chats: [ClaudeChat] = []
        for directory in directories(forProjectRoot: projectRoot) {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let id = String(name.dropLast(".jsonl".count))
                guard seen.insert(id).inserted,
                      let chat = read(url: directory.appendingPathComponent(name), id: id) else { continue }
                chats.append(chat)
            }
        }
        return chats.sorted { $0.lastExchange > $1.lastExchange }
    }

    /// Where the conversations of a folder may sit. Claude Code turns every
    /// `/` into `-`; some versions turn every other symbol into `-` too.
    static func directories(forProjectRoot root: String) -> [URL] {
        let expanded = NSString(string: root).expandingTildeInPath
        let slashes = ClaudeTranscripts.encodedDirectoryName(forProjectRoot: expanded)
        let symbols = String(expanded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
        return (slashes == symbols ? [slashes] : [slashes, symbols]).map {
            ClaudeTranscripts.projectsDirectory.appendingPathComponent($0, isDirectory: true)
        }
    }

    static func read(url: URL, id: String) -> ClaudeChat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var summary = TranscriptSummary()
        // The bookkeeping after the last exchange can be long; read further
        // back only when it pushed the exchange out of the window.
        for window in [UInt64(128 * 1024), UInt64(1024 * 1024), UInt64(8 * 1024 * 1024)] {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd() else { return nil }
            summary = TranscriptSummary.reading(tail: data, isWholeFile: start == 0)
            if summary.lastExchange != nil || start == 0 { break }
        }
        guard let lastExchange = summary.lastExchange else { return nil }
        if summary.customTitle == nil, summary.aiTitle == nil {
            if (try? handle.seek(toOffset: 0)) != nil, let head = try? handle.read(upToCount: 256 * 1024) {
                summary.fill(fromHead: head)
            }
        }
        return ClaudeChat(
            id: id,
            title: summary.title ?? "Untitled chat",
            lastPrompt: summary.lastPrompt,
            lastExchange: lastExchange
        )
    }

    /// One line, trimmed and bounded; nil when nothing is left.
    static func oneLine(_ text: String) -> String? {
        let flat = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > maximumTitleLength ? String(flat.prefix(maximumTitleLength - 1)) + "…" : flat
    }

    // MARK: - Running conversations

    static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// The conversations a Claude Code process runs right now, anywhere on
    /// this Mac, from the `~/.claude/sessions/<pid>.json` each one keeps.
    static func runningConversationIDs(directory: URL = sessionsDirectory) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var running = Set<String>()
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["sessionId"] as? String,
                  let pid = (json["pid"] as? NSNumber)?.int32Value else { continue }
            let startedAt = (json["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            if ProcessLiveness.isAlive(pid: pid, startedAt: startedAt) { running.insert(id) }
        }
        return running
    }
}

// MARK: - The list, as the Chats popover shows it

enum ChatHistory {
    enum Period: CaseIterable {
        case today
        case yesterday
        case previousWeek
        case previousMonth
        case older

        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .previousWeek: return "Previous 7 days"
            case .previousMonth: return "Previous 30 days"
            case .older: return "Older"
            }
        }
    }

    static func period(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> Period {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: return .today
        case 1: return .yesterday
        case 2..<7: return .previousWeek
        case 7..<30: return .previousMonth
        default: return .older
        }
    }

    /// The chats under their period, newest first in each, empty periods left out.
    static func grouped(
        _ chats: [ClaudeChat],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(period: Period, chats: [ClaudeChat])] {
        let sorted = chats.sorted { $0.lastExchange > $1.lastExchange }
        let byPeriod = Dictionary(grouping: sorted) { period(of: $0.lastExchange, now: now, calendar: calendar) }
        return Period.allCases.compactMap { period in
            byPeriod[period].map { (period, $0) }
        }
    }

    /// Chats whose title or last prompt holds every word of the query,
    /// accents and case aside.
    static func matching(_ chats: [ClaudeChat], query: String) -> [ClaudeChat] {
        let words = SidebarVisibility.fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return chats }
        return chats.filter { chat in
            let haystack = SidebarVisibility.fold(chat.title + " " + (chat.lastPrompt ?? ""))
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
