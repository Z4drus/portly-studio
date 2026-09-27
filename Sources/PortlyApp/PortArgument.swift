import Foundation

/// Hands the configured port to dev servers that ignore `$PORT`.
///
/// Portly always exports `PORT`, which Next.js, Nuxt and Create React App
/// read. Vite and the tools built on it (SvelteKit, Astro, React Router,
/// Remix), Angular and Expo only take a flag, so a plain `pnpm run dev` there
/// would come up on the framework's default port rather than the one chosen in
/// Portly. The configured command stays the plain script everybody types; the
/// flag is added when the server is spawned.
enum PortArgument {
    /// The command to spawn for `command` on `port`, run from `directory`.
    /// Anything that is not a bare package script, or whose script already
    /// names a port, is returned untouched.
    static func launchCommand(for command: String, port: Int?, directory: String) -> String {
        guard let port,
              let invocation = ScriptInvocation(command),
              let script = script(named: invocation.script, in: directory),
              needsPortFlag(script: script)
        else { return command }
        return invocation.appending(["--port", String(port)])
    }

    /// True when the script starts a tool that ignores `$PORT` and does not
    /// already pass a port of its own.
    static func needsPortFlag(script: String) -> Bool {
        // Chained or piped scripts start several things; guessing which one is
        // the server is how a flag ends up on a code generator.
        let separators = ["&&", "||", ";", "|", "&"]
        guard !separators.contains(where: { script.contains($0) }) else { return false }
        let tokens = script.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.contains(where: { $0 == "-p" || $0 == "--port" || $0.hasPrefix("--port=") }) { return false }
        // Skip `cross-env`, `env` and `NAME=value` prefixes to find the tool.
        let command = tokens.drop { token in
            token == "cross-env" || token == "env" || (token.contains("=") && !token.hasPrefix("-"))
        }
        guard let tool = command.first else { return false }
        // Options take values (`--host 0.0.0.0`, `--mode staging`), so the
        // subcommand is looked for among the words rather than taken as the
        // first one without a dash.
        let words = Set(command.dropFirst())
        switch tool {
        case "vite":
            // `vite`, `vite dev`, `vite serve`, `vite preview` all listen.
            return words.isDisjoint(with: ["build", "optimize"])
        case "astro": return !words.isDisjoint(with: ["dev", "preview"])
        case "ng": return words.contains("serve")
        case "expo": return words.contains("start")
        case "react-router": return words.contains("dev")
        case "remix": return words.contains("vite:dev")
        case "storybook": return words.contains("dev")
        default: return false
        }
    }

    private static func script(named name: String, in directory: String) -> String? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any]
        else { return nil }
        return scripts[name] as? String
    }
}

/// `pnpm run dev`, `npm run dev`, `bun run dev`, `yarn dev` and friends: a
/// package manager running one script with nothing else on the line.
struct ScriptInvocation: Equatable {
    let manager: String
    let script: String
    private let command: String

    init?(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        switch tokens.count {
        case 3 where tokens[1] == "run" && ["npm", "pnpm", "yarn", "bun"].contains(tokens[0]):
            manager = tokens[0]
            script = tokens[2]
        // pnpm and yarn run a script from its bare name too.
        case 2 where ["pnpm", "yarn"].contains(tokens[0]) && !tokens[1].hasPrefix("-"):
            manager = tokens[0]
            script = tokens[1]
        default:
            return nil
        }
        self.command = trimmed
    }

    /// Arguments for the script itself. npm needs `--` to stop reading them
    /// as its own options; the others pass on what follows the script name.
    func appending(_ arguments: [String]) -> String {
        let joined = arguments.joined(separator: " ")
        return manager == "npm" ? "\(command) -- \(joined)" : "\(command) \(joined)"
    }
}
