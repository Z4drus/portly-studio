import Combine
import CoreServices
import Foundation

// MARK: - Running git

/// Finds and runs the `git` binary without ever prompting. `/usr/bin/git` on a
/// Mac without the Command Line Tools is a stub that opens an install dialog,
/// so it is only used once a real installation is known to be behind it.
enum GitCommand {
    struct Result {
        var status: Int32
        var output: Data
        var text: String { String(decoding: output, as: UTF8.self) }
        var succeeded: Bool { status == 0 }
    }

    static let executable: URL? = locate()

    private static func locate() -> URL? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        for entry in LoginEnvironment.path.split(separator: ":") {
            let path = "\(entry)/git"
            if path != "/usr/bin/git", !candidates.contains(path) { candidates.append(path) }
        }
        let toolchains = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        if toolchains.contains(where: { fm.isExecutableFile(atPath: $0) }) {
            candidates.append("/usr/bin/git")
        }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// Runs `git <arguments>` in `directory`, bounded in time. Never touches
    /// the index (`--no-optional-locks`), never asks for credentials.
    static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 15) -> Result? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--no-optional-locks", "-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment
        LoginEnvironment.apply(to: &environment)
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
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
        return Result(status: process.terminationStatus, output: data)
    }
}

// MARK: - Reading a repository

/// Reads one project's repository into a `GitSnapshot`. Several git calls,
/// all read-only, all off the main thread.
enum GitSnapshotReader {
    static let recentCommitLimit = 60
    /// Untracked files bigger than this are not counted line by line, and
    /// counting stops once this many files or bytes have been read.
    static let untrackedLineCountLimit = 2 * 1024 * 1024
    static let untrackedFileCountLimit = 200
    static let untrackedByteLimit = 16 * 1024 * 1024

    /// The repository's top-level folder, or nil when the path is not inside
    /// a work tree (a bare repository, or no repository at all).
    static func repositoryRoot(for directory: String) -> String? {
        guard let result = GitCommand.run(["rev-parse", "--show-toplevel"], in: directory, timeout: 8),
              result.succeeded else { return nil }
        let root = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    static func read(root: String, envFiles: [String]) -> GitSnapshot? {
        guard let statusResult = GitCommand.run(
            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
            in: root
        ), statusResult.succeeded else { return nil }
        let status = GitOutputParser.parseStatus(statusResult.output)

        var snapshot = GitSnapshot()
        snapshot.branch = status.branch
        snapshot.upstream = status.upstream
        snapshot.ahead = status.ahead
        snapshot.behind = status.behind
        snapshot.isInitial = status.isInitial
        snapshot.files = status.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        applyLineCounts(to: &snapshot, root: root)
        snapshot.commits = recentCommits(root: root, isInitial: status.isInitial)
        snapshot.ignoredEnvFiles = ignoredFiles(among: envFiles, root: root)
        snapshot.remoteWebURL = remoteWebURL(root: root)
        return snapshot
    }

    /// Lines added and removed per path: tracked changes from `git diff`
    /// against HEAD (index and working tree together), untracked files by
    /// reading them.
    private static func applyLineCounts(to snapshot: inout GitSnapshot, root: String) {
        guard !snapshot.files.isEmpty else { return }
        var counts: [String: GitOutputParser.LineCount] = [:]
        let arguments = snapshot.isInitial
            ? ["diff", "--numstat", "-z", "--cached"]
            : ["diff", "--numstat", "-z", "HEAD"]
        if let result = GitCommand.run(arguments, in: root), result.succeeded {
            for count in GitOutputParser.parseNumstat(result.output) { counts[count.path] = count }
        }
        if snapshot.isInitial, let result = GitCommand.run(["diff", "--numstat", "-z"], in: root), result.succeeded {
            for count in GitOutputParser.parseNumstat(result.output) {
                var merged = counts[count.path] ?? count
                if counts[count.path] != nil {
                    merged.added += count.added
                    merged.removed += count.removed
                }
                counts[count.path] = merged
            }
        }
        var untrackedRead = 0
        var untrackedBytes = 0
        for index in snapshot.files.indices {
            let file = snapshot.files[index]
            if let count = counts[file.path] {
                snapshot.files[index].linesAdded = count.added
                snapshot.files[index].linesRemoved = count.removed
                snapshot.files[index].isBinary = count.isBinary
            } else if file.kind == .untracked {
                guard untrackedRead < untrackedFileCountLimit, untrackedBytes < untrackedByteLimit else { continue }
                let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? Int, size <= untrackedLineCountLimit,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                untrackedRead += 1
                untrackedBytes += size
                let counted = GitOutputParser.countLines(in: data)
                snapshot.files[index].linesAdded = counted.lines
                snapshot.files[index].isBinary = counted.isBinary
            }
        }
    }

    /// The last commits of every branch, newest first, each marked when no
    /// remote has it yet.
    private static func recentCommits(root: String, isInitial: Bool) -> [GitCommit] {
        guard !isInitial else { return [] }
        guard let log = GitCommand.run(
            ["log", "--date-order", "--max-count=\(recentCommitLimit)", "--branches", "--remotes", "--tags", "--format=\(GitOutputParser.logFormat)"],
            in: root
        ), log.succeeded else { return [] }
        var commits = GitOutputParser.parseLog(log.output)
        // Commits the remotes do not have: the ones still to push.
        if let local = GitCommand.run(
            ["rev-list", "--max-count=400", "--branches", "--not", "--remotes"],
            in: root
        ), local.succeeded {
            let hashes = Set(local.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            if !hashes.isEmpty {
                for index in commits.indices where hashes.contains(commits[index].hash) {
                    commits[index].isLocalOnly = true
                }
            }
        }
        return commits
    }

    /// Which of the given root files Git ignores.
    private static func ignoredFiles(among names: [String], root: String) -> [String] {
        guard !names.isEmpty,
              let result = GitCommand.run(["check-ignore", "--"] + names, in: root)
        else { return [] }
        // Exit code 1 means nothing is ignored; the output is authoritative.
        // `-z` is only accepted with `--stdin`; `.env*` names hold no newline.
        return result.text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    }

    private static func remoteWebURL(root: String) -> URL? {
        guard let result = GitCommand.run(["remote", "get-url", "origin"], in: root, timeout: 5), result.succeeded else { return nil }
        return GitOutputParser.webURL(fromRemote: result.text)
    }
}

// MARK: - Watching a repository

/// Keeps one project's Git state fresh while something on screen shows it.
///
/// Refreshes when files change under the project (FSEvents, debounced), on a
/// slow timer as a safety net, and whenever the popover opens. Everything
/// published here changes on the main thread; the git calls run on a serial
/// queue of their own, one refresh at a time, and a request made during a
/// refresh is served by one more pass afterwards.
final class GitRepositoryMonitor: ObservableObject {
    /// The project root as configured; the repository may start above it.
    let projectRoot: String

    /// Nil until the first check; false when the folder is not a repository.
    @Published private(set) var isRepository: Bool?
    @Published private(set) var snapshot: GitSnapshot?
    @Published private(set) var isRefreshing = false
    /// The repository's top-level folder, when there is one.
    @Published private(set) var repositoryRoot: String?

    private let queue = DispatchQueue(label: "dev.portly.git.monitor", qos: .utility)
    private var activeViews = 0
    private var stream: FSEventStreamRef?
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var refreshInFlight = false
    private var refreshRequested = false
    private var lastRefreshStarted: Date?
    /// The repository check is repeated now and then: `git init` may happen
    /// after the project was added.
    private var lastRepositoryCheck: Date?

    private static let debounceInterval: TimeInterval = 0.6
    private static let minimumInterval: TimeInterval = 1.5
    private static let timerInterval: TimeInterval = 20
    private static let repositoryRecheckInterval: TimeInterval = 30
    /// Folders whose churn says nothing about the repository: build output,
    /// dependencies, Git's own object store.
    static let ignoredFolders: Set<String> = [
        "node_modules", ".next", ".nuxt", ".build", "dist", "build", ".turbo", ".cache", ".swc",
        ".parcel-cache", ".vercel", "coverage", "target", "DerivedData", ".venv", "__pycache__",
    ]

    init(projectRoot: String) {
        self.projectRoot = NSString(string: projectRoot).expandingTildeInPath
    }

    deinit {
        stopWatching()
    }

    // MARK: Lifecycle

    /// A view started showing this repository: watch it, and read it now.
    func activate() {
        activeViews += 1
        if activeViews == 1 {
            startWatching()
            startTimer()
        }
        requestRefresh(immediately: true)
    }

    /// The view went away. The last one to leave stops the watching.
    func deactivate() {
        activeViews = max(0, activeViews - 1)
        if activeViews == 0 {
            stopWatching()
            timer?.invalidate()
            timer = nil
        }
    }

    /// Read again now: the popover opened, or the user asked.
    func refreshNow() {
        requestRefresh(immediately: true)
    }

    // MARK: Refreshing

    private func requestRefresh(immediately: Bool) {
        debounce?.cancel()
        let delay: TimeInterval
        if immediately {
            delay = 0
        } else {
            let sinceLast = lastRefreshStarted.map { Date().timeIntervalSince($0) } ?? .infinity
            delay = max(Self.debounceInterval, Self.minimumInterval - sinceLast)
        }
        let work = DispatchWorkItem { [weak self] in self?.performRefresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performRefresh() {
        if refreshInFlight {
            refreshRequested = true
            return
        }
        refreshInFlight = true
        lastRefreshStarted = Date()
        let root = projectRoot
        let knownRepositoryRoot = repositoryRoot
        let recheck = lastRepositoryCheck.map { Date().timeIntervalSince($0) > Self.repositoryRecheckInterval } ?? true
        if isRepository == nil || (isRepository == false && recheck) || snapshot == nil {
            isRefreshing = true
        }
        queue.async { [weak self] in
            var repository = knownRepositoryRoot
            if repository == nil || recheck {
                repository = GitSnapshotReader.repositoryRoot(for: root)
            }
            let envFiles = EnvFile.scan(root: root).map(\.name)
            let snapshot = repository.flatMap { GitSnapshotReader.read(root: $0, envFiles: envFiles) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastRepositoryCheck = Date()
                self.refreshInFlight = false
                self.isRefreshing = false
                if let repository {
                    if self.repositoryRoot != repository { self.repositoryRoot = repository }
                    if self.isRepository != true { self.isRepository = true }
                    if let snapshot, snapshot != self.snapshot { self.snapshot = snapshot }
                } else {
                    if self.isRepository != false { self.isRepository = false }
                    if self.snapshot != nil { self.snapshot = nil }
                    if self.repositoryRoot != nil { self.repositoryRoot = nil }
                }
                GitCenter.shared.record(root: root, isRepository: repository != nil)
                if self.refreshRequested {
                    self.refreshRequested = false
                    self.requestRefresh(immediately: false)
                }
            }
        }
    }

    // MARK: File watching

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            self?.requestRefresh(immediately: false)
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func startWatching() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<GitRepositoryMonitor>.fromOpaque(info).takeUnretainedValue()
            guard let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            monitor.filesChanged(Array(changed.prefix(count)))
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [projectRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.8,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Called on the monitor's queue with the folders FSEvents saw change.
    private func filesChanged(_ paths: [String]) {
        guard paths.contains(where: { !Self.isNoise($0, root: projectRoot) }) else { return }
        DispatchQueue.main.async { [weak self] in self?.requestRefresh(immediately: false) }
    }

    /// Inside `.git`, only these say the repository moved: a commit, a
    /// checkout, a fetch, a staging. Objects, hooks, logs and locks do not.
    static let meaningfulGitEntries: Set<String> = ["HEAD", "index", "refs", "packed-refs", "ORIG_HEAD", "MERGE_HEAD", "FETCH_HEAD"]

    /// True for a path inside a folder whose churn never changes `git status`.
    static func isNoise(_ path: String, root: String) -> Bool {
        var relative = path
        if relative.hasPrefix(root) { relative = String(relative.dropFirst(root.count)) }
        let components = relative.split(separator: "/").map(String.init)
        if components.first == ".git" {
            // The .git folder itself (FSEvents names the folder, not the file).
            guard components.count >= 2 else { return false }
            return !meaningfulGitEntries.contains(components[1])
        }
        return components.contains { ignoredFolders.contains($0) }
    }
}

/// One monitor per project root, shared by every view that shows the same
/// repository, so a project open in two places is read once. Also remembers
/// which roots turned out to be repositories, so the toolbar can leave the
/// Git button out of a project that has none.
///
/// Monitors live as long as the app: FSEvents holds an unretained pointer to
/// its monitor, which is only safe because nothing here ever drops one.
final class GitCenter: ObservableObject {
    static let shared = GitCenter()

    @Published private(set) var repositories: [String: Bool] = [:]
    private var monitors: [String: GitRepositoryMonitor] = [:]
    private var probing: Set<String> = []
    private var lastProbe: [String: Date] = [:]
    private let probeQueue = DispatchQueue(label: "dev.portly.git.probe", qos: .utility)

    /// A root found not to be a repository is asked again after this long,
    /// in case `git init` happened since.
    private static let reprobeInterval: TimeInterval = 30

    private init() {}

    func monitor(forRoot root: String) -> GitRepositoryMonitor {
        let key = NSString(string: root).expandingTildeInPath
        if let existing = monitors[key] { return existing }
        let created = GitRepositoryMonitor(projectRoot: key)
        monitors[key] = created
        return created
    }

    /// Whether the project folder is in a Git repository. Answers from what
    /// is known; until Git has been asked, a `.git` entry at the root is the
    /// guess, and Git is asked in the background (a project folder may sit
    /// deep inside a repository, with no `.git` of its own).
    func isRepository(root: String) -> Bool {
        let key = NSString(string: root).expandingTildeInPath
        let known = repositories[key]
        let stale = lastProbe[key].map { Date().timeIntervalSince($0) > Self.reprobeInterval } ?? true
        if known == nil || (known == false && stale) { probe(key) }
        return known ?? FileManager.default.fileExists(atPath: key + "/.git")
    }

    private func probe(_ key: String) {
        guard !probing.contains(key) else { return }
        probing.insert(key)
        lastProbe[key] = Date()
        probeQueue.async { [weak self] in
            let found = GitSnapshotReader.repositoryRoot(for: key) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing.remove(key)
                self.record(root: key, isRepository: found)
            }
        }
    }

    fileprivate func record(root: String, isRepository: Bool) {
        lastProbe[root] = Date()
        if repositories[root] != isRepository { repositories[root] = isRepository }
    }
}
