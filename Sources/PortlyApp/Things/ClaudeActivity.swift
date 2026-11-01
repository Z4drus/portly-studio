import Darwin
import Foundation

/// What Claude Code says about its running sessions, and what you last asked
/// each of them, read from the files it keeps under `~/.claude`.
enum ClaudeActivity {
    /// One live entry of `~/.claude/sessions/<pid>.json`.
    struct Session: Equatable {
        let pid: Int32
        let sessionID: String
        let cwd: String
        let status: AgentStatus
    }

    /// Something you typed, as opposed to a tool result or a note Claude
    /// Code adds on its own.
    struct HumanPrompt: Equatable {
        let id: String
        let text: String
    }

    static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - Sessions

    /// The sessions whose process still runs. The sorting agent's own runs
    /// are left out: they are Portly's, not yours.
    static func liveSessions(directory: URL = claudeDirectory.appendingPathComponent("sessions", isDirectory: true)) -> [Session] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = session(json: json),
                  session.cwd != ThingsTriage.workingDirectory.path
            else { return nil }
            let startedAt = (json["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return ProcessLiveness.isAlive(pid: session.pid, startedAt: startedAt) ? session : nil
        }
    }

    static func session(json: [String: Any]) -> Session? {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value,
              let sessionID = json["sessionId"] as? String,
              let cwd = json["cwd"] as? String else { return nil }
        let status: AgentStatus
        switch (json["tempo"] as? String, json["status"] as? String) {
        case ("blocked", _), (_, "waiting"): status = .waiting
        case ("active", _), (_, "busy"): status = .busy
        default: status = .idle
        }
        return Session(pid: pid, sessionID: sessionID, cwd: cwd, status: status)
    }

    // MARK: - Which terminal

    /// The Portly terminal a process runs in: the nearest ancestor that is
    /// one of the terminals' shells. A Claude Code launched by a pane's
    /// preset and one you typed into a free terminal are both children of
    /// that terminal's shell.
    static func terminal(of pid: Int32, shells: [Int32: String], parent: (Int32) -> Int32? = parentPID) -> String? {
        var current = pid
        for _ in 0..<12 {
            if let terminal = shells[current] { return terminal }
            guard let next = parent(current), next > 1, next != current else { return nil }
            current = next
        }
        return nil
    }

    static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Transcripts

    /// `~/.claude/projects/<folder>/<session>.jsonl`. Claude Code turns every
    /// character that is not a letter or a digit into `-`; older versions
    /// only replaced `/`. A shallow scan covers anything else.
    static func transcriptURL(sessionID: String, cwd: String, projects: URL = claudeDirectory.appendingPathComponent("projects", isDirectory: true)) -> URL? {
        let fileManager = FileManager.default
        let file = "\(sessionID).jsonl"
        let candidates = [
            String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }),
            cwd.replacingOccurrences(of: "/", with: "-"),
        ]
        for folder in candidates {
            let url = projects.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(file)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        let folders = (try? fileManager.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders
            .map { projects.appendingPathComponent($0, isDirectory: true).appendingPathComponent(file) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// The last thing you typed in the conversation. Read from the end, with
    /// a wider window when a long tool result or paste pushed it out.
    static func latestHumanPrompt(transcript url: URL) -> HumanPrompt? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        for window in [UInt64(256 * 1024), UInt64(2 * 1024 * 1024), UInt64(16 * 1024 * 1024)] {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            if let prompt = latestHumanPrompt(inTail: data, isWholeFile: start == 0) { return prompt }
            if start == 0 { return nil }
        }
        return nil
    }

    /// The newest human entry of a transcript tail. The first line of a tail
    /// read mid-file is partial and skipped.
    static func latestHumanPrompt(inTail data: Data, isWholeFile: Bool) -> HumanPrompt? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        let marker = Data(#""type":"user""#.utf8)
        for line in lines.reversed() where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let prompt = humanPrompt(entry: object) else { continue }
            return prompt
        }
        return nil
    }

    static func humanPrompt(entry: [String: Any]) -> HumanPrompt? {
        guard entry["type"] as? String == "user",
              entry["isMeta"] as? Bool != true,
              entry["isSidechain"] as? Bool != true,
              entry["toolUseResult"] == nil,
              let message = entry["message"] as? [String: Any] else { return nil }
        if let origin = entry["origin"] as? [String: Any], let kind = origin["kind"] as? String, kind != "human" {
            return nil
        }
        let text: String
        if let content = message["content"] as? String {
            text = content
        } else if let blocks = message["content"] as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash commands, their output and interruptions are bookkeeping.
        let bookkeeping = ["<command-", "<local-command", "[Request interrupted", "<bash-"]
        guard !trimmed.isEmpty, !bookkeeping.contains(where: { trimmed.hasPrefix($0) }) else { return nil }
        guard let id = (entry["promptId"] as? String) ?? (entry["uuid"] as? String) else { return nil }
        return HumanPrompt(id: id, text: trimmed)
    }
}
