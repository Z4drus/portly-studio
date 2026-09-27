import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Network
import UserNotifications

/// Keeps the Mac awake while agents work, then lets it sleep for real.
///
/// Turning it on arms it; it holds sleep only while an agent is working, lets
/// go once every agent has been idle for a while, and holds again the moment
/// one starts. Two signals say an agent is working: Claude Code's own status
/// (`busy` in `~/.claude/sessions/<pid>.json`, for every session on the Mac,
/// wherever it was started) and output in a Portly terminal, for the other
/// agents.
///
/// While holding: a power assertion stops idle sleep, a second one keeps the
/// screen on (lid open), and optionally `pmset disablesleep` keeps a closed
/// lid from cutting Wi-Fi and every agent with it. That last layer needs an
/// administrator once: the first activation installs a sudo rule limited to
/// the two `pmset` commands, and never asks again. With the lid closed the
/// built-in screen is put to sleep (or, if it will not go dark, dimmed to its
/// minimum), and once the agents are done the Mac is sent to sleep.
///
/// Everything is released when the agents have been idle for a while, when the
/// network is really gone, when the battery runs low, and when the app quits.
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

    /// The switch, remembered across launches.
    @Published private(set) var isEnabled = false
    /// Sleep is being held right now: an agent works, or did a moment ago.
    @Published private(set) var isHolding = false
    @Published private(set) var lidSleepBlocked = false
    @Published private(set) var lidClosed = false
    /// The built-in screen would not go dark behind the closed lid, so it was
    /// dimmed to its minimum; its brightness comes back with the lid.
    @Published private(set) var screenDimmed = false
    @Published private(set) var networkOnline = true
    @Published private(set) var workingCount = 0
    /// When the agents last went quiet, nil while one is working. Published in
    /// place of a running seconds count: that changed on every tick and rebuilt
    /// the toolbar item that reads it, which flickers on recent macOS.
    @Published private(set) var idleSince: Date?
    @Published private(set) var lastAutoRelease: AutoRelease?
    @Published private(set) var sudoRuleInstalled = false
    @Published private(set) var lastError: String?
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var onBattery = false

    /// Minutes without any working agent before the Mac is allowed to sleep.
    @Published var idleMinutes: Int {
        didSet { defaults.set(idleMinutes, forKey: Keys.idleMinutes) }
    }

    /// Also keep the screen on while agents work with the lid open.
    @Published var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: Keys.keepScreenOn)
            updateScreenAssertion()
        }
    }

    /// Also block sleep with the lid closed (needs an administrator).
    @Published var blockLidSleep: Bool {
        didSet {
            defaults.set(blockLidSleep, forKey: Keys.blockLidSleep)
            guard isEnabled else { return }
            if blockLidSleep {
                ensureSudoRule()
                if isHolding { applyLidBlock() }
            } else {
                removeLidBlock()
            }
        }
    }

    private enum Keys {
        static let enabled = "keepAwake.enabled"
        static let idleMinutes = "keepAwake.idleMinutes"
        static let keepScreenOn = "keepAwake.keepScreenOn"
        static let blockLidSleep = "keepAwake.blockLidSleep"
        static let lidApplied = "keepAwake.lidApplied"
        static let dimmedFrom = "keepAwake.dimmedFrom"
    }

    static let workingWindow: TimeInterval = 8
    static let offlineGrace: TimeInterval = 90
    static let lowBatteryPercent = 10
    private static let tickInterval: TimeInterval = 3

    private let defaults = UserDefaults.standard
    private var sleepAssertion: IOPMAssertionID = 0
    private var screenAssertion: IOPMAssertionID = 0
    /// Keeps App Nap from stretching the ticker while the window is hidden:
    /// an agent that starts working must be noticed within seconds.
    private var activity: NSObjectProtocol?
    private var ticker: Timer?
    private var offlineSince: Date?
    private var lastScreenSleepRequest: Date?
    private var lastLidBlockAttempt: Date?
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "dev.portly.keepawake.network")

    private init() {
        let storedMinutes = defaults.integer(forKey: Keys.idleMinutes)
        idleMinutes = storedMinutes == 0 ? 5 : storedMinutes
        keepScreenOn = defaults.object(forKey: Keys.keepScreenOn) as? Bool ?? true
        blockLidSleep = defaults.object(forKey: Keys.blockLidSleep) as? Bool ?? true

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkOnline = path.status == .satisfied }
        }
        monitor.start(queue: monitorQueue)
        refreshBattery()
        checkSudoRule()
        screenDimmed = defaults.object(forKey: Keys.dimmedFrom) != nil
        repairAfterCrashIfNeeded()
        if defaults.bool(forKey: Keys.enabled) {
            // After the crash repair and the sudo check have had their turn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.enable(interactive: false) }
        }
    }

    // MARK: - Public

    func toggle() {
        if isEnabled { disable() } else { enable(interactive: true) }
    }

    /// Arm it. Only a click may ask for the administrator password; an
    /// automatic re-arm at launch goes without lid protection instead.
    func enable(interactive: Bool = true) {
        guard !isEnabled else { return }
        isEnabled = true
        defaults.set(true, forKey: Keys.enabled)
        lastError = nil
        lastAutoRelease = nil
        idleSince = nil
        offlineSince = nil
        if blockLidSleep, interactive { ensureSudoRule() }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Portly watches whether coding agents are working"
        )
        startTicker()
        evaluate()
    }

    func disable() {
        guard isEnabled else { return }
        release(reason: .manual)
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)
        stopTicker()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        idleSince = nil
        offlineSince = nil
    }

    /// Called on quit: never leave `disablesleep` or a dimmed screen behind.
    /// The switch itself is remembered for the next launch.
    func shutdown() {
        release(reason: .manual)
        removeLidBlock()
        restoreBrightness()
        stopTicker()
    }

    // MARK: - Evaluation

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.evaluate() }
        timer.tolerance = 0.5
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Agent terminals with output in the last few seconds, or Claude Code
    /// sessions that say they are busy, whichever is more: one agent is
    /// usually both. Shells are left out: a `tail -f` or a dev server in a
    /// quick terminal would otherwise keep the Mac up forever, lid closed.
    private func currentWorkingCount(now: Date) -> Int {
        let terminals = StudioWorkspace.shared.workingPaneCount(now: now, agentsOnly: true)
        let claude = MainActor.assumeIsolated { UsageCenter.shared.busyClaudeSessionCount }
        return max(terminals, claude)
    }

    /// The decision loop: hold while something is happening, release when the
    /// reason to stay awake is gone, and look after the screen meanwhile.
    func evaluate(now: Date = Date()) {
        refreshBattery()
        // Every assignment below is guarded: `@Published` notifies on each
        // write, changed or not, and this runs on a timer.
        let working = currentWorkingCount(now: now)
        if working != workingCount { workingCount = working }
        guard isEnabled else { return }

        if working > 0 {
            if idleSince != nil { idleSince = nil }
        } else if idleSince == nil {
            idleSince = now
        }
        if networkOnline {
            offlineSince = nil
        } else if offlineSince == nil {
            offlineSince = now
        }

        let decision = KeepAwakePolicy.decide(
            isHolding: isHolding,
            working: working > 0,
            idleSince: idleSince,
            idleMinutes: idleMinutes,
            offlineSince: offlineSince,
            lowBattery: onBattery && (batteryPercent ?? 100) <= Self.lowBatteryPercent,
            now: now
        )
        switch decision {
        case .hold: hold()
        case .release(let reason): release(reason: reason)
        case .keep: break
        }
        retryLidBlockIfNeeded(now: now)
        manageScreen(now: now)
    }

    /// `pmset` can fail once (the sudo rule was being installed, the machine
    /// was waking up). A hold must not stay without lid protection because of
    /// it, and a release must not leave `disablesleep` behind. Once a minute,
    /// not on every tick.
    private func retryLidBlockIfNeeded(now: Date) {
        let wantsBlock = isHolding && blockLidSleep
        let blocked = lidSleepBlocked || defaults.bool(forKey: Keys.lidApplied)
        guard wantsBlock != blocked, sudoRuleInstalled else { return }
        if let last = lastLidBlockAttempt, now.timeIntervalSince(last) < 60 { return }
        lastLidBlockAttempt = now
        if wantsBlock { applyLidBlock() } else { removeLidBlock() }
    }

    // MARK: - Holding

    private func hold() {
        guard !isHolding else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Portly Custom: coding agents are working" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            sleepAssertion = id
        } else {
            lastError = "Could not create the power assertion (\(result))."
        }
        isHolding = true
        lastAutoRelease = nil
        if blockLidSleep {
            lastLidBlockAttempt = Date()
            applyLidBlock()
        }
        updateScreenAssertion()
    }

    private func release(reason: ReleaseReason) {
        guard isHolding else { return }
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        isHolding = false
        updateScreenAssertion()
        restoreBrightness()
        removeLidBlock()
        lastScreenSleepRequest = nil
        guard reason != .manual else { return }
        lastAutoRelease = AutoRelease(reason: reason, date: Date())
        if reason != .agentsIdle {
            Self.notify(title: "Portly let the Mac sleep", body: "Keep awake paused: \(reason.message).")
        }
        // The lid was closed on working agents. They are done: sleep now, as
        // closing the lid would have done without Portly.
        if lidClosed, !DisplayPower.hasExternalDisplay() {
            DisplayPower.sleepSystem()
        }
    }

    /// The screen stays on while agents work with the lid open, when asked.
    /// Never with the lid closed: that is precisely the lit screen to avoid.
    private func updateScreenAssertion() {
        let wanted = isHolding && keepScreenOn && !lidClosed
        if wanted, screenAssertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Portly Custom: keeping the screen on while agents work" as CFString,
                &id
            )
            if result == kIOReturnSuccess { screenAssertion = id }
        } else if !wanted, screenAssertion != 0 {
            IOPMAssertionRelease(screenAssertion)
            screenAssertion = 0
        }
    }

    // MARK: - Lid and screen

    private func manageScreen(now: Date) {
        let closed = DisplayPower.isLidClosed()
        if closed != lidClosed {
            lidClosed = closed
            lastScreenSleepRequest = nil
            updateScreenAssertion()
        }
        let action = KeepAwakePolicy.screenAction(
            lidClosed: lidClosed,
            keepingMacAwake: isHolding && lidSleepBlocked,
            externalDisplay: lidClosed && DisplayPower.hasExternalDisplay(),
            builtInLit: lidClosed && DisplayPower.isBuiltInDisplayLit(),
            dimmed: screenDimmed,
            lastSleepRequest: lastScreenSleepRequest,
            now: now
        )
        switch action {
        case .none:
            break
        case .sleepScreen:
            lastScreenSleepRequest = now
            DisplayPower.sleepDisplays()
        case .dimAndSleepScreen:
            dimBuiltInScreen()
            lastScreenSleepRequest = now
            DisplayPower.sleepDisplays()
        case .restoreBrightness:
            restoreBrightness()
        }
    }

    private func dimBuiltInScreen() {
        guard !screenDimmed, let current = DisplayPower.builtInBrightness() else { return }
        // Written down first: a crash must not leave the screen at its minimum.
        defaults.set(Double(current), forKey: Keys.dimmedFrom)
        if DisplayPower.setBuiltInBrightness(0) { screenDimmed = true }
    }

    /// Gives the saved brightness back. Kept on file until it really is back:
    /// with another screen connected the built-in one can be unreachable, and
    /// the next tick, release or launch tries again.
    private func restoreBrightness() {
        guard let stored = defaults.object(forKey: Keys.dimmedFrom) as? Double else {
            if screenDimmed { screenDimmed = false }
            return
        }
        guard DisplayPower.setBuiltInBrightness(Float(stored)) else {
            if !screenDimmed { screenDimmed = true }
            return
        }
        defaults.removeObject(forKey: Keys.dimmedFrom)
        if screenDimmed { screenDimmed = false }
    }

    // MARK: - Lid sleep (pmset)

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

    /// A previous run may have died with `disablesleep 1` still set, or with
    /// the screen dimmed behind a closed lid.
    private func repairAfterCrashIfNeeded() {
        restoreBrightness()
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
            if batteryPercent != nil { batteryPercent = nil }
            if onBattery { onBattery = false }
            return
        }
        var percent = batteryPercent
        var battery = onBattery
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let capacity = description["Current Capacity"] as? Int {
                percent = capacity
            }
            if let state = description["Power Source State"] as? String {
                battery = state == "Battery Power"
            }
        }
        if percent != batteryPercent { batteryPercent = percent }
        if battery != onBattery { onBattery = battery }
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

/// The keep-awake decisions, apart from the side effects so they can be tested.
enum KeepAwakePolicy {
    enum Decision: Equatable {
        case hold
        case release(KeepAwake.ReleaseReason)
        case keep
    }

    enum ScreenAction: Equatable {
        case none
        case sleepScreen
        /// The screen stayed lit after being asked to sleep: dim it as well.
        case dimAndSleepScreen
        case restoreBrightness
    }

    /// How long a closed-lid screen gets to go dark before it is dimmed, and
    /// how often it is asked again while it stays lit.
    static let screenSleepGrace: TimeInterval = 10
    static let screenSleepRetry: TimeInterval = 30

    static func decide(
        isHolding: Bool,
        working: Bool,
        idleSince: Date?,
        idleMinutes: Int,
        offlineSince: Date?,
        lowBattery: Bool,
        now: Date
    ) -> Decision {
        if lowBattery { return isHolding ? .release(.lowBattery) : .keep }
        if let offlineSince, now.timeIntervalSince(offlineSince) >= KeepAwake.offlineGrace {
            return isHolding ? .release(.offline) : .keep
        }
        if working { return isHolding ? .keep : .hold }
        guard isHolding, let idleSince else { return .keep }
        return now.timeIntervalSince(idleSince) >= TimeInterval(idleMinutes * 60) ? .release(.agentsIdle) : .keep
    }

    /// With the lid closed on a Mac kept awake, its built-in screen must be
    /// dark. With the lid open, or another screen in use, nothing is touched
    /// beyond giving back a brightness taken earlier.
    static func screenAction(
        lidClosed: Bool,
        keepingMacAwake: Bool,
        externalDisplay: Bool,
        builtInLit: Bool,
        dimmed: Bool,
        lastSleepRequest: Date?,
        now: Date
    ) -> ScreenAction {
        guard lidClosed, keepingMacAwake, !externalDisplay else { return dimmed && !lidClosed ? .restoreBrightness : .none }
        guard builtInLit else { return .none }
        guard let lastSleepRequest else { return .sleepScreen }
        let elapsed = now.timeIntervalSince(lastSleepRequest)
        if !dimmed, elapsed >= screenSleepGrace { return .dimAndSleepScreen }
        return elapsed >= screenSleepRetry ? .sleepScreen : .none
    }
}
