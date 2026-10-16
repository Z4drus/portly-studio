import Foundation
import PortlyCore
import SwiftTerm

/// One bounded command supervised for an agent: `pnpm run build`, a test run,
/// a preview server that should live a minute. It runs in a PTY of its own so
/// tools keep their colours and progress bars, its output goes to a log an
/// agent reads with `portly logs <id>` or `portly wait <id>`, and a deadline
/// kills the whole process group so a hung build never outlives the agent.
///
/// Headless on purpose. Jobs are an agent's tool: they never reach the
/// sidebar, `config.json` or a terminal pane, and a finished one is forgotten
/// an hour later.
final class TemporaryJob: NSObject, LocalProcessDelegate {
    let id: String
    let name: String
    let command: String
    let directory: String
    let port: Int?
    let timeoutSeconds: Int
    private let extraEnvironment: [String: String]

    private(set) var state: TemporaryJobState = .running
    private(set) var pid: Int32?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var deadline: Date?
    private(set) var exitCode: Int32?
    private(set) var error: String?

    let logs: LogStore
    private var process: LocalProcess?
    private var timeoutWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?
    private var stopRequested = false
    private var timedOut = false

    /// Called on the main thread once the job has reached a final state.
    var onFinish: ((TemporaryJob) -> Void)?

    init(
        id: String = TemporaryJob.newID(),
        name: String,
        command: String,
        directory: String,
        port: Int?,
        env: [String: String],
        timeoutSeconds: Int,
        logBufferLines: Int,
        logFileMaxMB: Int
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.directory = directory
        self.port = port
        self.extraEnvironment = env
        self.timeoutSeconds = timeoutSeconds
        self.logs = LogStore(serverID: id, maxLines: logBufferLines, maxMB: logFileMaxMB)
        super.init()
    }

    static func newID() -> String { "tmp_" + String(UUID().uuidString.prefix(8)).lowercased() }

    var isRunning: Bool { state == .running }

    var status: TemporaryJobStatus {
        var url: String?
        if let port, isRunning, PortInspector.isListening(port: port) {
            url = "http://localhost:\(port)"
        }
        return TemporaryJobStatus(
            id: id,
            name: name,
            command: command,
            directory: directory,
            state: state,
            pid: pid,
            startedAt: startedAt,
            finishedAt: finishedAt,
            timeoutSeconds: timeoutSeconds,
            deadline: deadline,
            exitCode: exitCode,
            error: error,
            port: port,
            url: url
        )
    }

    // MARK: - Lifecycle

    func start() {
        LoginEnvironment.ensureResolved()
        var extra = extraEnvironment
        extra["PORTLY_JOB"] = id
        if let port { extra["PORT"] = String(port) }
        let proc = LocalProcess(delegate: self)
        process = proc
        logs.note("job \(id) started: \(command)  (cwd: \(directory), timeout: \(TemporaryTimeout.display(timeoutSeconds)))")
        proc.startProcess(
            executable: TerminalStyling.loginShell,
            args: ["-l", "-c", command],
            environment: TerminalStyling.environment(projectRoot: directory, extra: extra),
            execName: nil,
            currentDirectory: directory
        )
        pid = proc.shellPid
        let now = Date()
        startedAt = now
        deadline = now.addingTimeInterval(TimeInterval(timeoutSeconds))
        scheduleTimeout()
    }

    /// An explicit stop from the CLI. The job ends as `stopped`, not `failed`.
    func stop() {
        guard isRunning else { return }
        stopRequested = true
        logs.note("stopped by request")
        signalProcessGroup()
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.timedOut = true
            let message = "Timed out after \(TemporaryTimeout.display(self.timeoutSeconds))"
            self.error = message
            self.logs.note(message)
            self.signalProcessGroup()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(timeoutSeconds), execute: work)
    }

    /// SIGTERM to the whole group first, so a package manager's children go
    /// too; SIGKILL for whatever is still there a few seconds later.
    private func signalProcessGroup() {
        guard let process, process.running, process.shellPid > 0 else {
            finish(exitCode: nil)
            return
        }
        let pid = process.shellPid
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let proc = self.process, proc.running else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        killWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func finish(exitCode code: Int32?) {
        guard isRunning else { return }
        timeoutWork?.cancel()
        timeoutWork = nil
        killWork?.cancel()
        killWork = nil
        exitCode = code
        finishedAt = Date()
        pid = nil
        process = nil
        if timedOut {
            state = .timedOut
        } else if stopRequested {
            state = .stopped
        } else if code == 0 {
            state = .succeeded
        } else {
            state = .failed
            error = "Exited with code \(code.map(String.init) ?? "signal")"
        }
        logs.note("job \(id) \(state.rawValue) (exit \(code.map(String.init) ?? "signal"))")
        onFinish?(self)
    }

    // MARK: - LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let normalized = ServerRuntime.normalizedProcessExitCode(exitCode)
        DispatchQueue.main.async { [weak self] in
            self?.finish(exitCode: normalized)
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        logs.append(bytes: slice)
    }

    func getWindowSize() -> winsize {
        // Wide enough that build tools do not wrap their tables.
        winsize(ws_row: 40, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// Every temporary job of this app session, by id. Main thread only.
final class TemporaryJobCenter {
    static let shared = TemporaryJobCenter()

    /// How long a finished job stays readable, so a detached agent can still
    /// call `portly wait` on a command that finished in a second.
    static let retention: TimeInterval = 3_600

    private(set) var jobs: [String: TemporaryJob] = [:]

    private init() {}

    @discardableResult
    func run(
        name: String,
        command: String,
        directory: String,
        port: Int?,
        env: [String: String],
        timeoutSeconds: Int,
        settings: PortlyConfig
    ) -> TemporaryJob {
        let job = TemporaryJob(
            name: uniqueName(name),
            command: command,
            directory: directory,
            port: port,
            env: env,
            timeoutSeconds: timeoutSeconds,
            logBufferLines: settings.logBufferLines,
            logFileMaxMB: settings.logFileMaxMB
        )
        job.onFinish = { [weak self] job in self?.scheduleCleanup(job) }
        jobs[job.id] = job
        job.start()
        return job
    }

    func job(_ id: String) -> TemporaryJob? { jobs[id] }

    /// Newest first, the running ones before the finished ones.
    var statuses: [TemporaryJobStatus] {
        jobs.values
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
            }
            .map(\.status)
    }

    var runningCount: Int { jobs.values.filter(\.isRunning).count }

    /// Called on quit: the app is the supervisor, nothing outlives it.
    func terminateAll() {
        for job in jobs.values where job.isRunning {
            job.stop()
        }
    }

    private func scheduleCleanup(_ job: TemporaryJob) {
        let finishedAt = job.finishedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retention) { [weak self] in
            guard let self, let current = self.jobs[job.id], current.finishedAt == finishedAt else { return }
            self.jobs.removeValue(forKey: job.id)
            // A throwaway build's log has nothing to say an hour later.
            let log = PortlyPaths.logFile(forServer: job.id)
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: log.deletingPathExtension().appendingPathExtension("1.log"))
        }
    }

    private func uniqueName(_ requested: String) -> String {
        let base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "Temporary job" : base
        let taken = Set(jobs.values.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)".lowercased()) { suffix += 1 }
        return "\(name) \(suffix)"
    }
}
