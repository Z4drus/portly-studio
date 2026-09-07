import Foundation

/// Pre-approves a folder in Claude Code's workspace-trust store.
///
/// The first time Claude Code runs in a directory it asks "Is this a project you
/// created or one you trust?" and records the answer in its own global config
/// under `projects["<real path>"].hasTrustDialogAccepted`. There is no CLI flag
/// and no settings key for it, so a project Portly just created gets the same
/// treatment by writing that key before the first agent terminal opens.
enum ClaudeTrust {
    /// What `approve(root:)` did, so callers can report it without re-reading.
    enum Outcome: Equatable {
        /// The key was written; Claude Code will not ask for this folder.
        case approved
        /// Claude Code already trusted the folder; the file was left untouched.
        case alreadyApproved
        /// Claude Code never persists trust for the home directory itself.
        case homeDirectory
        /// No Claude Code config on this Mac: there is nothing to pre-approve.
        case notInstalled
    }

    enum TrustError: LocalizedError {
        case unreadableConfig(URL)

        var errorDescription: String? {
            switch self {
            case let .unreadableConfig(url):
                return "\(url.path) is not a JSON object Portly can extend."
            }
        }
    }

    private static let trustKey = "hasTrustDialogAccepted"
    private static let projectsKey = "projects"

    // MARK: - Locations

    /// Claude Code's global config file, resolved the way Claude Code resolves
    /// it: the legacy `.config.json` inside the Claude directory wins when that
    /// file exists, otherwise `.claude.json` in `CLAUDE_CONFIG_DIR` or `$HOME`.
    static func globalConfigFile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        let configDirectory = environment["CLAUDE_CONFIG_DIR"]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { value -> URL? in
                guard !value.isEmpty else { return nil }
                return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
            }

        let claudeDirectory = configDirectory ?? home.appendingPathComponent(".claude", isDirectory: true)
        let legacy = claudeDirectory.appendingPathComponent(".config.json")
        if fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return (configDirectory ?? home).appendingPathComponent(".claude.json")
    }

    /// True when Claude Code has a config on this Mac, so the UI can explain why
    /// pre-approval would be a no-op instead of failing silently.
    static func isInstalled(
        file: URL = ClaudeTrust.globalConfigFile(),
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: file.path)
    }

    /// The key Claude Code files a folder under: its resolved real path. `/tmp`
    /// and other symlinked roots resolve the same way on both sides, so the keys
    /// match.
    static func projectKey(for root: String) -> String {
        let expanded = NSString(string: root).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    }

    // MARK: - Approving

    /// Marks one folder trusted, leaving the file untouched when there is
    /// nothing to change — which is the common case once a project exists.
    @discardableResult
    static func approve(
        root: String,
        file: URL = ClaudeTrust.globalConfigFile(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let key = projectKey(for: root)
        guard key != projectKey(for: home.path) else { return .homeDirectory }
        guard fileManager.fileExists(atPath: file.path) else { return .notInstalled }
        let approved = try approve(keys: [key], file: file, fileManager: fileManager)
        return approved > 0 ? .approved : .alreadyApproved
    }

    /// Marks every folder trusted in a single read/write pass and returns how
    /// many of them were not trusted yet.
    @discardableResult
    static func approve(
        roots: [String],
        file: URL = ClaudeTrust.globalConfigFile(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard fileManager.fileExists(atPath: file.path) else { return 0 }
        let homeKey = projectKey(for: home.path)
        let keys = roots.map(projectKey(for:)).filter { $0 != homeKey }
        return try approve(keys: keys, file: file, fileManager: fileManager)
    }

    private static func approve(keys: [String], file: URL, fileManager: FileManager) throws -> Int {
        let data = try Data(contentsOf: file)
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrustError.unreadableConfig(file)
        }

        // The parse only classifies each key; the edits themselves are byte
        // splices, so this state is tracked by hand instead of re-parsing.
        var projects = config[projectsKey] as? [String: Any]
        var entries = Set((projects ?? [:]).keys)
        var trusted = Set((projects ?? [:]).compactMap { name, entry -> String? in
            (entry as? [String: Any])?[trustKey] as? Bool == true ? name : nil
        })

        var bytes = Array(data)
        var approved = 0
        for key in keys where !trusted.contains(key) {
            guard let patched = insertTrust(for: key, in: bytes, hasProjects: projects != nil, hasEntry: entries.contains(key)) else {
                throw TrustError.unreadableConfig(file)
            }
            bytes = patched
            projects = projects ?? [:]
            entries.insert(key)
            trusted.insert(key)
            approved += 1
        }

        guard approved > 0 else { return 0 }
        try write(bytes, to: file, fileManager: fileManager)
        return approved
    }

    /// Adds the trust flag for one folder at the shallowest place that works, so
    /// the splice stays small whatever the config already holds.
    private static func insertTrust(for key: String, in bytes: [UInt8], hasProjects: Bool, hasEntry: Bool) -> [UInt8]? {
        guard let flag = JSONObjectEditor.member(name: trustKey, value: true) else { return nil }
        if hasEntry {
            return JSONObjectEditor.inserting(flag, atPath: [projectsKey, key], in: bytes)
        }
        guard let entry = JSONObjectEditor.member(name: key, value: [trustKey: true]) else { return nil }
        if hasProjects {
            return JSONObjectEditor.inserting(entry, atPath: [projectsKey], in: bytes)
        }
        guard let projects = JSONObjectEditor.member(name: projectsKey, value: [key: [trustKey: true]]) else { return nil }
        return JSONObjectEditor.inserting(projects, atPath: [], in: bytes)
    }

    /// Atomic, and it restores the original mode: Claude Code keeps this file at
    /// 0600 and a plain write would widen it to the umask default.
    private static func write(_ bytes: [UInt8], to file: URL, fileManager: FileManager) throws {
        let permissions = try? fileManager.attributesOfItem(atPath: file.path)[.posixPermissions]
        try Data(bytes).write(to: file, options: .atomic)
        if let permissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
    }
}

/// Adds a member to a JSON object without re-serializing the document.
///
/// Claude Code's config holds about a thousand floating-point values, and
/// Foundation prints `0.1` back as `0.10000000000000001`; a round trip through
/// `JSONSerialization` would rewrite all of them. Splicing leaves every byte
/// outside the inserted member exactly as Claude Code wrote it.
enum JSONObjectEditor {
    /// A complete `"name": value` pair, ready to splice. `value` must be
    /// JSON-encodable; only small literals go through here, so the encoder's
    /// number formatting never reaches the document.
    static func member(name: String, value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [name: value], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8),
              text.count > 2
        else { return nil }
        return String(text.dropFirst().dropLast())
    }

    /// Inserts `member` as the first member of the object reached by walking
    /// `path` from the document root. Returns nil when the document is not an
    /// object or a step of `path` is missing or is not itself an object.
    static func inserting(_ member: String, atPath path: [String], in bytes: [UInt8]) -> [UInt8]? {
        guard var open = objectStart(in: bytes, from: 0) else { return nil }
        for name in path {
            guard let value = valueStart(ofMember: name, inObjectAt: open, bytes: bytes),
                  let nested = objectStart(in: bytes, from: value)
            else { return nil }
            open = nested
        }
        return inserting(member, intoObjectAt: open, bytes: bytes)
    }

    // MARK: - Scanning

    private static func objectStart(in bytes: [UInt8], from index: Int) -> Int? {
        let start = skipWhitespace(bytes, from: index)
        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else { return nil }
        return start
    }

    /// Index of the first byte of the value `name` maps to, in the object whose
    /// `{` sits at `open`.
    private static func valueStart(ofMember name: String, inObjectAt open: Int, bytes: [UInt8]) -> Int? {
        var index = skipWhitespace(bytes, from: open + 1)
        while index < bytes.count, bytes[index] != UInt8(ascii: "}") {
            guard let (key, afterKey) = string(bytes, from: index) else { return nil }
            var cursor = skipWhitespace(bytes, from: afterKey)
            guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") else { return nil }
            cursor = skipWhitespace(bytes, from: cursor + 1)
            if key == name { return cursor }
            guard let afterValue = skipValue(bytes, from: cursor) else { return nil }
            index = skipWhitespace(bytes, from: afterValue)
            if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                index = skipWhitespace(bytes, from: index + 1)
            }
        }
        return nil
    }

    private static func inserting(_ member: String, intoObjectAt open: Int, bytes: [UInt8]) -> [UInt8]? {
        let firstMember = skipWhitespace(bytes, from: open + 1)
        guard firstMember < bytes.count else { return nil }
        var text = member
        if bytes[firstMember] != UInt8(ascii: "}") {
            // Reuse the newline and indent the existing first member sits on, so
            // the splice reads like the rest of the file.
            let indent = String(decoding: bytes[(open + 1)..<firstMember], as: UTF8.self)
            text = indent + member + ","
        }
        var patched = bytes
        patched.insert(contentsOf: Array(text.utf8), at: open + 1)
        return patched
    }

    private static func skipWhitespace(_ bytes: [UInt8], from index: Int) -> Int {
        var cursor = index
        while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 || bytes[cursor] == 0x0A || bytes[cursor] == 0x0D {
            cursor += 1
        }
        return cursor
    }

    /// Decodes the string literal at `index` and reports where it ends.
    private static func string(_ bytes: [UInt8], from index: Int) -> (String, Int)? {
        guard let end = stringEnd(bytes, from: index),
              let decoded = try? JSONSerialization.jsonObject(
                  with: Data(bytes[index..<end]),
                  options: [.fragmentsAllowed]
              ) as? String
        else { return nil }
        return (decoded, end)
    }

    /// Index just past the closing quote of the string literal at `index`.
    private static func stringEnd(_ bytes: [UInt8], from index: Int) -> Int? {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        var cursor = index + 1
        while cursor < bytes.count {
            switch bytes[cursor] {
            case UInt8(ascii: "\\"): cursor += 2
            case UInt8(ascii: "\""): return cursor + 1
            default: cursor += 1
            }
        }
        return nil
    }

    private static func skipValue(_ bytes: [UInt8], from index: Int) -> Int? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            return stringEnd(bytes, from: index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            return containerEnd(bytes, from: index)
        default:
            // Numbers, true, false and null all run to the next structural byte.
            var cursor = index
            while cursor < bytes.count, !isStructural(bytes[cursor]) { cursor += 1 }
            return cursor > index ? cursor : nil
        }
    }

    private static func containerEnd(_ bytes: [UInt8], from index: Int) -> Int? {
        var depth = 0
        var cursor = index
        while cursor < bytes.count {
            switch bytes[cursor] {
            case UInt8(ascii: "\""):
                guard let end = stringEnd(bytes, from: cursor) else { return nil }
                cursor = end
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return cursor + 1 }
            default:
                break
            }
            cursor += 1
        }
        return nil
    }

    private static func isStructural(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
            || byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
