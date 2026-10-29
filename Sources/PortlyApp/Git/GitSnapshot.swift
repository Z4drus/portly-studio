import Foundation

// MARK: - What a repository looks like right now

/// How one path differs from the last commit.
enum GitChangeKind: String, Hashable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted

    /// The one-letter mark drawn in front of the file, as every Git client does.
    var mark: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .untracked: return "Untracked"
        case .conflicted: return "Conflict"
        }
    }

    /// The status letter Git prints in a porcelain entry, or nil for `.`.
    init?(statusLetter: Character) {
        switch statusLetter {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        default: return nil
        }
    }
}

/// One changed path, with how much of it moved.
struct GitFileChange: Identifiable, Hashable {
    /// Path relative to the repository root.
    var path: String
    /// The previous path of a rename or copy.
    var previousPath: String?
    var kind: GitChangeKind
    /// Part of the change is in the index, ready to commit.
    var staged: Bool
    /// Part of the change is still in the working tree only.
    var unstaged: Bool
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    /// Git could not count lines (an image, a lockfile that is binary…).
    var isBinary = false

    var id: String { path }

    var fileName: String { (path as NSString).lastPathComponent }

    /// The folder part, without the trailing slash, or nil at the root.
    var directory: String? {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }
}

/// One commit of the recent history.
struct GitCommit: Identifiable, Hashable {
    var hash: String
    var parents: [String]
    var subject: String
    var author: String
    var date: Date
    /// Branch and tag names pointing at the commit (`HEAD -> main`, `origin/main`, `tag: v1`).
    var refs: [String]
    /// Not on any remote yet: committed here, never pushed.
    var isLocalOnly = false

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }

    /// `HEAD -> main` becomes `main`; the `tag: ` prefix is dropped.
    var branchNames: [String] {
        refs.compactMap { ref in
            if ref.hasPrefix("HEAD -> ") { return String(ref.dropFirst("HEAD -> ".count)) }
            if ref == "HEAD" { return nil }
            if ref.hasPrefix("tag: ") { return String(ref.dropFirst("tag: ".count)) }
            return ref
        }
    }

    var isHead: Bool {
        refs.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }
    }
}

/// Everything the Git button and its popover show, read in one pass.
struct GitSnapshot: Hashable {
    /// The checked-out branch, or nil when HEAD is detached.
    var branch: String?
    /// `origin/main` when the branch tracks a remote branch.
    var upstream: String?
    /// Commits here that the upstream does not have (to push).
    var ahead = 0
    /// Commits on the upstream missing here (to pull).
    var behind = 0
    /// A repository with no commit yet.
    var isInitial = false
    var files: [GitFileChange] = []
    var commits: [GitCommit] = []
    /// `.env*` files at the root that Git ignores: present on disk, never committed.
    var ignoredEnvFiles: [String] = []
    /// The `origin` remote, when it is a web-browsable repository.
    var remoteWebURL: URL?

    var linesAdded: Int { files.reduce(0) { $0 + $1.linesAdded } }
    var linesRemoved: Int { files.reduce(0) { $0 + $1.linesRemoved } }
    var isClean: Bool { files.isEmpty }
    var hasConflicts: Bool { files.contains { $0.kind == .conflicted } }

    /// The numbers the toolbar pill shows, so a refresh that changed nothing
    /// visible does not redraw the toolbar.
    struct Summary: Hashable {
        var linesAdded: Int
        var linesRemoved: Int
        var ahead: Int
        var fileCount: Int
        var hasConflicts: Bool
    }

    var summary: Summary {
        Summary(linesAdded: linesAdded, linesRemoved: linesRemoved, ahead: ahead, fileCount: files.count, hasConflicts: hasConflicts)
    }
}

// MARK: - Parsing what Git prints

/// Turns Git's machine-readable output into the snapshot. Pure functions, so
/// every format quirk can be pinned by a test.
enum GitOutputParser {
    /// `git status --porcelain=v2 --branch -z`: the branch headers and one
    /// entry per changed path, NUL-terminated (a rename carries its old path
    /// in a second NUL-terminated field).
    struct Status: Hashable {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var isInitial = false
        var files: [GitFileChange] = []
    }

    static func parseStatus(_ data: Data) -> Status {
        var status = Status()
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }
            if field.hasPrefix("# ") {
                parseHeader(field, into: &status)
                continue
            }
            let tokens = field.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard let type = tokens.first else { continue }
            switch type {
            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                guard tokens.count >= 9 else { continue }
                let path = tokens[8...].joined(separator: " ")
                if let change = ordinaryChange(xy: tokens[1], path: path, previousPath: nil) {
                    status.files.append(change)
                }
            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path> NUL <origPath>
                guard tokens.count >= 10 else { continue }
                let path = tokens[9...].joined(separator: " ")
                let previous = index < fields.count ? fields[index] : nil
                index += 1
                if let change = ordinaryChange(xy: tokens[1], path: path, previousPath: previous) {
                    status.files.append(change)
                }
            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                guard tokens.count >= 11 else { continue }
                let path = tokens[10...].joined(separator: " ")
                status.files.append(GitFileChange(path: path, kind: .conflicted, staged: false, unstaged: true))
            case "?":
                let path = field.dropFirst(2)
                status.files.append(GitFileChange(path: String(path), kind: .untracked, staged: false, unstaged: true))
            default:
                // "!" ignored entries are not requested; anything else is noise.
                continue
            }
        }
        return status
    }

    private static func parseHeader(_ line: String, into status: inout Status) {
        let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "branch.oid":
            status.isInitial = parts[1] == "(initial)"
        case "branch.head":
            status.branch = parts[1] == "(detached)" ? nil : parts[1]
        case "branch.upstream":
            status.upstream = parts[1]
        case "branch.ab":
            for token in parts[1].split(separator: " ") {
                if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    /// `XY`: X is the index, Y the working tree; `.` means untouched there.
    private static func ordinaryChange(xy: String, path: String, previousPath: String?) -> GitFileChange? {
        let letters = Array(xy)
        guard letters.count == 2 else { return nil }
        let staged = GitChangeKind(statusLetter: letters[0])
        let unstaged = GitChangeKind(statusLetter: letters[1])
        guard let kind = staged ?? unstaged else { return nil }
        // A rename in the index that was then edited reads as renamed, which
        // is what the file list should say; the line counts carry the edit.
        var change = GitFileChange(
            path: path,
            previousPath: previousPath,
            kind: kind,
            staged: staged != nil,
            unstaged: unstaged != nil
        )
        if staged == .added, unstaged == .deleted { change.kind = .deleted }
        return change
    }

    /// `git diff --numstat -z`: `added TAB removed TAB path NUL`, and for a
    /// rename `added TAB removed TAB NUL old NUL new NUL`. `-` marks binary.
    struct LineCount: Hashable {
        var path: String
        var added: Int
        var removed: Int
        var isBinary: Bool
    }

    static func parseNumstat(_ data: Data) -> [LineCount] {
        var counts: [LineCount] = []
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }
            let columns = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 3 else { continue }
            let isBinary = columns[0] == "-"
            let added = Int(columns[0]) ?? 0
            let removed = Int(columns[1]) ?? 0
            var path = columns[2]
            if path.isEmpty {
                // Rename: the old path, then the new one, follow as fields.
                guard index + 1 < fields.count else { break }
                path = fields[index + 1]
                index += 2
            }
            counts.append(LineCount(path: path, added: added, removed: removed, isBinary: isBinary))
        }
        return counts
    }

    /// Record separator between commits and field separator inside one, as
    /// asked for with `%x1e` and `%x1f` in the log format.
    static let logFormat = "%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%s%x1e"

    static func parseLog(_ data: Data) -> [GitCommit] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { return nil }
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { return nil }
            let refs = fields[2]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return GitCommit(
                hash: hash,
                parents: fields[1].split(separator: " ").map(String.init),
                subject: fields[5].trimmingCharacters(in: .whitespacesAndNewlines),
                author: fields[3],
                date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                refs: refs
            )
        }
    }

    /// `git remote get-url origin`, turned into the page a browser can open:
    /// `git@github.com:owner/repo.git` and `https://github.com/owner/repo.git`
    /// both become `https://github.com/owner/repo`.
    static func webURL(fromRemote remote: String) -> URL? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("git@"), let colon = value.firstIndex(of: ":") {
            let host = value[value.index(value.startIndex, offsetBy: 4)..<colon]
            let path = value[value.index(after: colon)...]
            value = "https://\(host)/\(path)"
        } else if value.hasPrefix("ssh://") {
            value = value.replacingOccurrences(of: "ssh://", with: "https://")
            if let at = value.firstIndex(of: "@") {
                value = "https://" + value[value.index(after: at)...]
            }
        }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        guard value.hasPrefix("http://") || value.hasPrefix("https://"),
              var components = URLComponents(string: value), components.host != nil else { return nil }
        // A remote may carry a token (`https://user:token@host/…`): it has no
        // place in a link, let alone in the browser's history.
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Lines in a file that Git does not track yet, so an untracked file
    /// counts as added lines like the others. Binary content counts nothing.
    static func countLines(in data: Data) -> (lines: Int, isBinary: Bool) {
        guard !data.isEmpty else { return (0, false) }
        let probe = data.prefix(8000)
        if probe.contains(0) { return (0, true) }
        var lines = 0
        for byte in data where byte == UInt8(ascii: "\n") { lines += 1 }
        if data.last != UInt8(ascii: "\n") { lines += 1 }
        return (lines, false)
    }
}

// MARK: - What is said to the agent

/// The sentences the Git popover types into the focused terminal. Said the
/// way the user says them: the agent then runs the Git commands itself.
enum GitAgentMessages {
    /// The request made several times a day: everything goes, including the
    /// files another agent or a human touched.
    static let commitAndPush =
        "Est-ce que tu peux tout commit and push s'il te plaît, même les modifications qui ne t'appartiennent pas ? "
}
