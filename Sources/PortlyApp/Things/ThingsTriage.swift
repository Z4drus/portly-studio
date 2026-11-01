import Foundation

/// The sorting agent: one headless Claude Code run (`claude -p`) that reads a
/// prompt you sent to an agent and says which Things to-do it moves forward.
///
/// It runs without tools, MCP servers, hooks or your settings, and answers in
/// JSON checked against a schema, so all it can do is answer. Portly adds the
/// branch itself from that answer.
enum ThingsTriage {
    static let model = "sonnet"
    static let effort = "medium"
    /// A prompt longer than this is cut: the start says what it is about.
    static let promptLimit = 4000
    static let timeout: TimeInterval = 120

    struct Request: Equatable {
        let prompt: String
        /// The terminal's folder, a strong hint: a client's folder is that client's work.
        let directory: String
        /// The Portly project the terminal belongs to, if any.
        let projectName: String?
    }

    enum Verdict: Equatable {
        case task(id: String, label: String)
        case unrelated
    }

    enum Failure: Error, LocalizedError, Equatable {
        case claudeNotFound
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: return "Claude Code was not found on this Mac."
            case .failed(let message): return message
            case .timedOut: return "The sorting agent took too long."
            }
        }
    }

    /// An empty folder of its own: no CLAUDE.md to pick up, and its runs are
    /// easy to tell apart from yours in `~/.claude/sessions`.
    static var workingDirectory: URL {
        StudioStore.defaultURL.deletingLastPathComponent().appendingPathComponent("things-triage", isDirectory: true)
    }

    static let systemPrompt = """
    Tu tries le travail qu'une personne lance dans des terminaux Claude Code. On te donne ses tâches \
    Things (sa liste de choses à faire, une ligne par tâche avec un identifiant) et le prompt qu'elle \
    vient d'envoyer à un agent, avec le dossier du terminal.

    Si ce prompt fait clairement avancer une des tâches, réponds l'identifiant de cette tâche et un \
    libellé de 2 à 6 mots en français, à l'infinitif, volontairement vague, qui dit quelle partie de la \
    tâche l'agent fait (par exemple « Rédiger 2 articles », « Préparer le devis », « Corriger le \
    formulaire »). Pas de nom de client dans le libellé : la tâche le dit déjà.

    Le dossier du terminal est un indice fort : un terminal ouvert dans le dossier d'un client travaille \
    pour ce client. Un terminal dans le dossier personnel peut concerner n'importe quelle tâche, par \
    exemple un devis.

    Si aucune tâche ne correspond clairement (une demande ponctuelle d'un client, une question générale, \
    un autre projet), réponds taskId null et label null. Dans le doute, null.
    """

    static let schema = """
    {"type":"object","properties":{"taskId":{"type":["string","null"]},"label":{"type":["string","null"]}},"required":["taskId","label"],"additionalProperties":false}
    """

    /// The message for the agent, and the short ids it answers with mapped
    /// back to Things ids. Short ids are harder to get wrong than uuids.
    static func message(tasks: [ThingsTask], request: Request) -> (text: String, ids: [String: String]) {
        var ids: [String: String] = [:]
        var lines: [String] = []
        for (index, task) in tasks.enumerated() {
            let id = "t\(index + 1)"
            ids[id] = task.id
            var line = "- \(id): \(task.title)"
            if let project = task.projectTitle { line += " (projet Things : \(project))" }
            let notes = ThingsBoard.excerpt(of: task.notes, limit: 160)
            if !notes.isEmpty { line += " — notes : \(notes)" }
            lines.append(line)
        }
        var prompt = request.prompt
        if prompt.count > promptLimit { prompt = String(prompt.prefix(promptLimit)) + "\n[…]" }
        var context = "Dossier du terminal : \(request.directory)"
        if let project = request.projectName { context += "\nProjet Portly : \(project)" }
        let text = """
        Tâches :
        \(lines.joined(separator: "\n"))

        \(context)

        Prompt envoyé à l'agent :
        \"\"\"
        \(prompt)
        \"\"\"
        """
        return (text, ids)
    }

    /// Reads `claude -p --output-format json`: the schema-checked answer
    /// sits under `structured_output`.
    static func verdict(output: Data, ids: [String: String]) throws -> Verdict {
        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw Failure.failed("The sorting agent gave an answer Portly could not read.")
        }
        if json["is_error"] as? Bool == true {
            let detail = (json["result"] as? String).map { ThingsBoard.excerpt(of: $0, limit: 120) } ?? "unknown error"
            throw Failure.failed("The sorting agent failed: \(detail)")
        }
        guard let answer = json["structured_output"] as? [String: Any] else {
            throw Failure.failed("The sorting agent answered without the expected fields.")
        }
        guard let short = answer["taskId"] as? String, let taskID = ids[short] else { return .unrelated }
        let label = ((answer["label"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "«»\"'.")))
        return .task(id: taskID, label: label.isEmpty ? "Avancer la tâche" : String(label.prefix(60)))
    }

    static func arguments() -> [String] {
        [
            "-p",
            "--model", model,
            "--effort", effort,
            "--no-session-persistence",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--system-prompt", systemPrompt,
            "--output-format", "json",
            "--json-schema", schema,
        ]
    }

    /// Claude Code as your terminal finds it.
    static func claudeExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let directories = LoginEnvironment.path.split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        return directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// One run, off the main thread. The prompt goes in on stdin: it can be
    /// long, and nothing in it ever reaches a shell.
    static func run(tasks: [ThingsTask], request: Request) async throws -> Verdict {
        LoginEnvironment.ensureResolved()
        guard let executable = claudeExecutable() else { throw Failure.claudeNotFound }
        let (text, ids) = message(tasks: tasks, request: request)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments()
                process.currentDirectoryURL = workingDirectory
                var environment = TerminalStyling.sanitized(ProcessInfo.processInfo.environment)
                LoginEnvironment.apply(to: &environment)
                process.environment = environment
                let input = Pipe()
                let output = Pipe()
                let errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors

                var timedOut = false
                let timer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut = true
                    process.terminate()
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.failed("Portly could not start Claude Code: \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                input.fileHandleForWriting.write(Data(text.utf8))
                try? input.fileHandleForWriting.close()
                // Drain both pipes before waiting, or a full pipe blocks the run.
                var errorData = Data()
                let drainErrors = DispatchWorkItem { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
                DispatchQueue.global().async(execute: drainErrors)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                drainErrors.wait()
                timer.cancel()

                if timedOut {
                    continuation.resume(throwing: Failure.timedOut)
                } else if process.terminationStatus != 0, data.isEmpty {
                    let detail = String(decoding: errorData, as: UTF8.self)
                    continuation.resume(throwing: Failure.failed(
                        "The sorting agent stopped with code \(process.terminationStatus): \(ThingsBoard.excerpt(of: detail, limit: 120))"
                    ))
                } else {
                    do {
                        continuation.resume(returning: try verdict(output: data, ids: ids))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
