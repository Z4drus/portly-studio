import AppKit
import Combine
import Darwin
import Foundation

/// Watches one profile's `sessions` directory — `~/.claude/sessions` by
/// default — and publishes the Claude Code sessions that are actually running,
/// wherever they were started: a Portly terminal, another terminal, VS Code.
///
/// The directory is watched rather than polled, because Claude Code writes a
/// session file the moment its state changes. A slow timer runs alongside
/// purely to notice processes that died without touching the directory.
@MainActor
final class ClaudeSessionMonitor: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private let directory: URL
    private let livenessInterval: TimeInterval

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var livenessTimer: Timer?
    private var debounce: DispatchWorkItem?

    init(directory: URL, livenessInterval: TimeInterval = 5) {
        self.directory = directory
        self.livenessInterval = livenessInterval
    }

    func start() {
        rescan()
        watchDirectory()

        let timer = Timer(timeInterval: livenessInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    func stop() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        debounce?.cancel()
        source?.cancel()
        source = nil
    }

    private func watchDirectory() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }   // no directory yet; the timer still covers us

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
    }

    /// A single state change can produce several file events; coalesce them.
    private func scheduleRescan() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func rescan() {
        let found = Self.read(directory: directory)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(directory: URL) -> [AgentSession] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> AgentSession? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let record = ClaudeSessionRecord(json: json),
                      ProcessLiveness.isAlive(pid: record.pid, startedAt: record.startedAt)
                else { return nil }
                return record.session
            }
            .sorted { $0.since > $1.since }
    }
}

/// One entry in `~/.claude/sessions/<pid>.json`, as Claude Code writes it.
/// Decoded leniently on purpose: the file is written by another program on
/// its own release schedule.
struct ClaudeSessionRecord {
    let pid: Int32
    /// Roughly when the process started. Only used to notice a recycled pid.
    let startedAt: Date?
    let session: AgentSession

    init?(json: [String: Any]) {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value,
              let cwd = json["cwd"] as? String else { return nil }

        let raw = json["status"] as? String
        let tempo = json["tempo"] as? String
        let state: AgentSession.State
        switch (tempo, raw) {
        case ("blocked", _), (_, "waiting"): state = .waiting
        case ("active", _), (_, "busy"): state = .busy
        default: state = .idle
        }

        let millis = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue
            ?? (json["updatedAt"] as? NSNumber)?.doubleValue

        self.pid = pid
        if let started = (json["startedAt"] as? NSNumber)?.doubleValue {
            self.startedAt = Date(timeIntervalSince1970: started / 1000)
        } else {
            self.startedAt = (json["procStart"] as? String).flatMap(Self.parseProcStart)
        }

        let folder = (cwd as NSString).lastPathComponent
        self.session = AgentSession(
            id: "claude.\(pid)",
            name: (json["name"] as? String) ?? folder,
            detail: "\(Self.surface(json["entrypoint"] as? String)) · \(folder)",
            state: state,
            waitingFor: (json["waitingFor"] as? String) ?? (json["needs"] as? String),
            since: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        )
    }

    static func surface(_ entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": return "Desktop"
        case "claude-vscode": return "VS Code"
        case "local-agent": return "Agent"
        default: return "Terminal"
        }
    }

    /// `procStart` looks like "Fri Aug 28 05:15:20 2026": a ctime string in
    /// UTC, with the day of month space-padded on single-digit days.
    static func parseProcStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter.date(from: collapsed)
    }
}

/// Is a pid still running, and is it still the *same* process? A session that
/// crashes leaves its file behind saying `busy` forever, and pids get reused.
enum ProcessLiveness {
    static func isAlive(pid: Int32, startedAt: Date?) -> Bool {
        guard exists(pid: pid) else { return false }
        guard let startedAt, let actual = startTime(pid: pid) else {
            return true
        }
        return abs(actual.timeIntervalSince(startedAt)) < reuseTolerance
    }

    /// Wide enough to absorb the gap between process start and registration,
    /// tight enough that a recycled pid never slips through.
    private static let reuseTolerance: TimeInterval = 5 * 60

    private static func exists(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        // EPERM means it exists but belongs to someone else.
        return errno == EPERM
    }

    static func startTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
}
