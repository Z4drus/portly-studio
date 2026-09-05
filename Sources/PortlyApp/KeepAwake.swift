import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Network
import UserNotifications

/// Keeps the Mac awake while agents work, then lets it sleep for real.
///
/// Two layers: a power-management assertion (no privileges, stops idle sleep
/// while the display may still go dark) and, optionally, `pmset disablesleep`
/// so a closed lid does not cut Wi-Fi and every running agent with it. That
/// second layer needs an administrator once: the first activation installs a
/// sudo rule limited to the two `pmset` commands, and never asks again. Everything is released when the agents have
/// been idle for a while, when the network is really gone, when the battery
/// runs low, and when the app quits.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    enum ReleaseReason: String {
        case agentsIdle
        case offline
        case lowBattery
        case manual

        var message: String {
            switch self {
            case .agentsIdle: return "every agent has been idle, so the Mac may sleep again"
            case .offline: return "the network went away, so the Mac may sleep again"
            case .lowBattery: return "the battery is low, so the Mac may sleep again"
            case .manual: return "turned off"
            }
        }
    }

    struct AutoRelease: Equatable {
        let reason: ReleaseReason
        let date: Date
    }

    @Published private(set) var isActive = false
    @Published private(set) var lidSleepBlocked = false
    @Published private(set) var networkOnline = true
    @Published private(set) var workingCount = 0
    @Published private(set) var idleSeconds = 0
    @Published private(set) var lastAutoRelease: AutoRelease?
    @Published private(set) var sudoRuleInstalled = false
    @Published private(set) var lastError: String?
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var onBattery = false

    /// Minutes without any agent output before the Mac is allowed to sleep.
    @Published var idleMinutes: Int {
        didSet { defaults.set(idleMinutes, forKey: Keys.idleMinutes) }
    }

    /// Also block sleep with the lid closed (needs an administrator).
    @Published var blockLidSleep: Bool {
        didSet {
            defaults.set(blockLidSleep, forKey: Keys.blockLidSleep)
            guard isActive else { return }
            if blockLidSleep { applyLidBlock() } else { removeLidBlock() }
        }
    }

    private enum Keys {
        static let idleMinutes = "keepAwake.idleMinutes"
        static let blockLidSleep = "keepAwake.blockLidSleep"
        static let lidApplied = "keepAwake.lidApplied"
    }

    static let workingWindow: TimeInterval = 8
    private static let offlineGrace: TimeInterval = 90
    private static let lowBatteryPercent = 10

    private let defaults = UserDefaults.standard
    private var assertion: IOPMAssertionID = 0
    private var ticker: Timer?
    private var idleSince: Date?
    private var offlineSince: Date?
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "dev.portly.keepawake.network")

    private init() {
        let storedMinutes = defaults.integer(forKey: Keys.idleMinutes)
        idleMinutes = storedMinutes == 0 ? 5 : storedMinutes
        blockLidSleep = defaults.object(forKey: Keys.blockLidSleep) as? Bool ?? true

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkOnline = path.status == .satisfied }
        }
        monitor.start(queue: monitorQueue)
        refreshBattery()
        checkSudoRule()
        repairAfterCrashIfNeeded()
    }

    // MARK: - Public

    func toggle() {
        if isActive { deactivate(reason: .manual) } else { activate() }
    }

    func activate() {
        guard !isActive else { return }
        lastError = nil
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Portly Custom: coding agents are working" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertion = id
        } else {
            lastError = "Could not create the power assertion (\(result))."
        }
        isActive = true
        idleSince = nil
        offlineSince = nil
        lastAutoRelease = nil
        if blockLidSleep {
            ensureSudoRule()
            applyLidBlock()
        }
        startTicker()
        evaluate()
    }

    func deactivate(reason: ReleaseReason) {
        guard isActive else { return }
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        removeLidBlock()
        isActive = false
        stopTicker()
        idleSince = nil
        offlineSince = nil
        idleSeconds = 0
        if reason != .manual {
            lastAutoRelease = AutoRelease(reason: reason, date: Date())
            Self.notify(title: "Portly let the Mac sleep", body: "Keep awake ended: \(reason.message).")
        }
    }

    /// Called on quit: never leave `disablesleep` behind.
    func shutdown() {
        if isActive { deactivate(reason: .manual) } else { removeLidBlock() }
    }

    /// One password, once: a sudoers rule for exactly the two `pmset`
    /// commands Portly uses. Every later toggle runs silently.
    private func ensureSudoRule() {
        sudoRuleInstalled = Self.sudoRuleAllowsPmset()
        guard !sudoRuleInstalled else { return }
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let script = "printf '%s\\n' '\(rule)' > /etc/sudoers.d/portly-pmset && chmod 0440 /etc/sudoers.d/portly-pmset && /usr/sbin/visudo -cf /etc/sudoers.d/portly-pmset"
        switch runPrivileged(script) {
        case .success:
            lastError = nil
            sudoRuleInstalled = Self.sudoRuleAllowsPmset()
        case .failure(let error):
            lastError = "Lid protection needs a one-time administrator approval: \(error.localizedDescription)"
        }
    }

    // MARK: - Evaluation

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.evaluate() }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// The decision loop: hold while something is happening, release when the
    /// reason to stay awake is gone.
    func evaluate(now: Date = Date()) {
        refreshBattery()
        workingCount = StudioWorkspace.shared.workingPaneCount()
        guard isActive else { return }

        if workingCount > 0 {
            idleSince = nil
            idleSeconds = 0
        } else {
            if idleSince == nil { idleSince = now }
            idleSeconds = Int(now.timeIntervalSince(idleSince ?? now))
            if idleSeconds >= idleMinutes * 60 {
                deactivate(reason: .agentsIdle)
                return
            }
        }

        if networkOnline {
            offlineSince = nil
        } else {
            if offlineSince == nil { offlineSince = now }
            if now.timeIntervalSince(offlineSince ?? now) >= Self.offlineGrace {
                deactivate(reason: .offline)
                return
            }
        }

        if onBattery, let percent = batteryPercent, percent <= Self.lowBatteryPercent {
            deactivate(reason: .lowBattery)
        }
    }

    // MARK: - Lid sleep (pmset)

    private func applyLidBlock() {
        guard !lidSleepBlocked else { return }
        switch runPmset(disableSleep: true) {
        case .success:
            lidSleepBlocked = true
            defaults.set(true, forKey: Keys.lidApplied)
            lastError = nil
        case .failure(let error):
            lidSleepBlocked = false
            lastError = "Lid protection needs an administrator: \(error.localizedDescription)"
        }
    }

    private func removeLidBlock() {
        guard lidSleepBlocked || defaults.bool(forKey: Keys.lidApplied) else { return }
        switch runPmset(disableSleep: false) {
        case .success:
            lidSleepBlocked = false
            defaults.set(false, forKey: Keys.lidApplied)
        case .failure(let error):
            lastError = "Could not restore normal sleep: \(error.localizedDescription)"
        }
    }

    /// A previous run may have died with `disablesleep 1` still set.
    private func repairAfterCrashIfNeeded() {
        guard defaults.bool(forKey: Keys.lidApplied) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.sudoRuleInstalled = Self.sudoRuleAllowsPmset()
            self.removeLidBlock()
        }
    }

    private func runPmset(disableSleep: Bool) -> Result<Void, Error> {
        let value = disableSleep ? "1" : "0"
        guard sudoRuleInstalled else {
            return .failure(NSError(
                domain: "dev.portly.keepawake",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "the administrator rule is not installed"]
            ))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .success(()) }
            return .failure(NSError(
                domain: "dev.portly.keepawake",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "pmset exited with \(process.terminationStatus)"]
            ))
        } catch {
            return .failure(error)
        }
    }

    /// `do shell script … with administrator privileges`: the standard macOS
    /// password sheet, on the main thread.
    private func runPrivileged(_ command: String) -> Result<Void, Error> {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSApp.activate(ignoringOtherApps: true)
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "authorization failed"
            return .failure(NSError(domain: "dev.portly.keepawake", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        return .success(())
    }

    private func checkSudoRule() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let installed = Self.sudoRuleAllowsPmset()
            DispatchQueue.main.async { self?.sudoRuleInstalled = installed }
        }
    }

    /// `sudo -n -l <command>` exits 0 only when the rule lets it run silently.
    private static func sudoRuleAllowsPmset() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Battery

    private func refreshBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            batteryPercent = nil
            onBattery = false
            return
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let capacity = description["Current Capacity"] as? Int {
                batteryPercent = capacity
            }
            if let state = description["Power Source State"] as? String {
                onBattery = state == "Battery Power"
            }
        }
    }

    // MARK: - Notifications

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "keepawake-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
