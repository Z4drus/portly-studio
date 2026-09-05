import Foundation

/// The PATH your terminal has, for an app that macOS started with almost none.
///
/// Launched from the Dock, an app gets `/usr/bin:/bin:/usr/sbin:/sbin`. Tools
/// like pnpm, bun or nvm live in directories that `~/.zshrc` adds, and a
/// non-interactive login shell never reads that file. So ask an interactive
/// login shell once, and hand its PATH to every process Portly starts.
enum LoginEnvironment {
    private static let lock = NSLock()
    private static var resolvedPath: String?
    private static var resolving = false
    private static let resolvedGroup = DispatchGroup()
    private static var groupEntered = false

    /// Best PATH known right now: the shell's once resolved, a generous
    /// default until then.
    static var path: String {
        lock.lock()
        defer { lock.unlock() }
        return merged(shellPath: resolvedPath)
    }

    static func apply(to environment: inout [String: String]) {
        environment["PATH"] = path
    }

    /// Runs the user's shell in the background and caches its PATH.
    static func resolveIfNeeded() {
        lock.lock()
        guard resolvedPath == nil, !resolving else {
            lock.unlock()
            return
        }
        resolving = true
        if !groupEntered {
            groupEntered = true
            resolvedGroup.enter()
        }
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let found = queryShellPath()
            lock.lock()
            resolving = false
            if let found, !found.isEmpty { resolvedPath = found }
            let entered = groupEntered
            groupEntered = false
            lock.unlock()
            if let found {
                // The app's own `Process` calls (sudo, git…) benefit too.
                setenv("PATH", merged(shellPath: found), 1)
            }
            if entered { resolvedGroup.leave() }
        }
    }

    /// Blocks briefly when a process starts before the shell answered, so the
    /// very first `pnpm dev` after launch still finds its tools.
    static func ensureResolved(timeout: TimeInterval = 5) {
        resolveIfNeeded()
        lock.lock()
        let pending = resolvedPath == nil && resolving
        lock.unlock()
        guard pending else { return }
        _ = resolvedGroup.wait(timeout: .now() + timeout)
    }

    /// `zsh -ilc 'print -r -- $PATH'`: interactive so `.zshrc` runs, login so
    /// `.zprofile` does. Bounded, because a chatty rc file must not hang us.
    static func queryShellPath(timeout: TimeInterval = 6) -> String? {
        let shell = loginShell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        let marker = "__PORTLY_PATH__"
        let command = shell.hasSuffix("fish")
            ? "printf '%s%s\\n' \(marker) \"$PATH\""
            : "printf '%s%s\\n' '\(marker)' \"$PATH\""
        process.arguments = ["-ilc", command]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment.removeValue(forKey: "PORTLY")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Take the last marker line: rc files may print before it.
        let line = text.split(separator: "\n").last { $0.hasPrefix(marker) }
        return line.map { String($0.dropFirst(marker.count)) }
    }

    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// Shell PATH first, then the usual tool homes, then the system, deduplicated.
    static func merged(shellPath: String?, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let usual = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/Library/pnpm", "\(home)/.bun/bin",
            "\(home)/.cargo/bin", "\(home)/.volta/bin", "\(home)/.deno/bin",
        ]
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        var result: [String] = []
        let shellEntries = (shellPath ?? "").split(separator: ":").map { stabilised(String($0)) }
        for entry in shellEntries + usual + system
        where !entry.isEmpty && seen.insert(entry).inserted {
            result.append(entry)
        }
        return result.joined(separator: ":")
    }

    /// fnm and similar managers hand each shell a throwaway symlink directory
    /// that disappears with that shell. Keep the real installation behind it.
    static func stabilised(_ entry: String) -> String {
        guard entry.contains("fnm_multishells") || entry.contains("/.nvm/") else { return entry }
        let resolved = URL(fileURLWithPath: entry).resolvingSymlinksInPath().path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : entry
    }
}
