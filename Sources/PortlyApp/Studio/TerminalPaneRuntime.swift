import AppKit
import Foundation
import SwiftTerm

/// Shared look for every terminal Portly draws: server output and coding
/// sessions read as one surface.
enum TerminalStyling {
    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "GeistMono-Regular", size: size)
            ?? NSFont(name: "JetBrainsMono-Regular", size: size)
            ?? NSFont(name: "CommitMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// A calm, editor-inspired ANSI palette. Bright variants remain distinct
    /// without the saturated red/green/blue of the default terminal palette.
    static let palette: [SwiftTerm.Color] = [
        color(0x1B1D23), // black
        color(0xFF6B81), // red
        color(0xA7D46F), // green
        color(0xF5C76D), // yellow
        color(0x82AAFF), // blue
        color(0xC792EA), // magenta
        color(0x63D4D5), // cyan
        color(0xD8DEE9), // white
        color(0x5C6370), // bright black
        color(0xFF879A), // bright red
        color(0xC3E88D), // bright green
        color(0xFFD580), // bright yellow
        color(0x9CC4FF), // bright blue
        color(0xDDB6F2), // bright magenta
        color(0x89DDFF), // bright cyan
        color(0xFFFFFF), // bright white
    ]

    static func color(_ hex: UInt32) -> SwiftTerm.Color {
        let red = UInt16((hex >> 16) & 0xFF) * 257
        let green = UInt16((hex >> 8) & 0xFF) * 257
        let blue = UInt16(hex & 0xFF) * 257
        return SwiftTerm.Color(red: red, green: green, blue: blue)
    }

    static func apply(to view: TerminalView, fontSize: CGFloat) {
        view.font = font(size: fontSize)
        view.nativeForegroundColor = TerminalTheme.foreground
        view.nativeBackgroundColor = TerminalTheme.background
        view.installColors(palette)
        view.useBrightColors = true
        view.caretColor = NSColor(srgbRed: 0.49, green: 0.78, blue: 1, alpha: 1)
        view.caretTextColor = TerminalTheme.background
        view.selectedTextBackgroundColor = NSColor(srgbRed: 0.16, green: 0.22, blue: 0.32, alpha: 1)
        view.selectedTextForegroundColor = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1)
    }

    /// The user's login shell, so aliases and PATH match their real terminal.
    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// Variables an agent session leaves behind. When the app itself was
    /// launched from inside Claude Code (say, `open` from a terminal), a
    /// nested `claude` would otherwise think it is a child session and stop
    /// saving transcripts. A login shell rebuilds anything legitimate.
    static let inheritedAgentPrefixes = ["CLAUDE", "CODEX_", "CURSOR_", "ITERM_", "TMUX", "TERM_SESSION_ID", "SHLVL"]

    static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !inheritedAgentPrefixes.contains { key.hasPrefix($0) }
        }
    }

    static func environment(projectRoot: String, extra: [String: String] = [:]) -> [String] {
        var env = sanitized(ProcessInfo.processInfo.environment)
        LoginEnvironment.apply(to: &env)
        env.removeValue(forKey: "NO_COLOR")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Portly"
        env["PORTLY"] = "1"
        env["PORTLY_STUDIO"] = "1"
        env["PORTLY_PROJECT_ROOT"] = projectRoot
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (key, value) in extra { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }
    }
}

/// How the Option key behaves in every terminal Portly draws.
///
/// SwiftTerm defaults to Option-as-Meta, which sends `ESC` plus the bare key and
/// drops the character the layout would have produced. On a US layout nobody
/// notices; on Swiss, German, French and most other ISO layouts it makes
/// `{ } [ ] @ | ~ #` and the backslash impossible to type. So Option composes
/// characters, as it does everywhere else on the Mac, and stays Meta only for
/// the keys that produce no character: ⌥← and ⌥⌫ still move and delete by word.
enum TerminalOptionKey {
    /// Arrows and the editing keys, by virtual key code.
    static let metaKeyCodes: Set<UInt16> = [
        123, 124, 125, 126, // arrows
        51, 117,            // backspace, forward delete
        36, 76, 48, 53,     // return, enter, tab, escape
        115, 119, 116, 121, // home, end, page up, page down
    ]

    static func actsAsMeta(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.option) && metaKeyCodes.contains(keyCode)
    }

    /// SwiftTerm keeps `keyDown` closed to subclasses, so the mode is set from
    /// the app's key monitor just before the event reaches the view.
    static func prepare(_ view: TerminalView, for event: NSEvent) {
        let wanted = actsAsMeta(keyCode: event.keyCode, modifiers: event.modifierFlags)
        if view.optionAsMetaKey != wanted { view.optionAsMetaKey = wanted }
    }
}

/// When the launch screen over a new agent terminal may lift.
///
/// Nothing in the byte stream says "Claude Code is ready", and the prompt
/// format changes between versions, so readiness is read from the shape of
/// the output instead: the shell prompt and the typed command arrive first
/// and are small; the agent's first screen is big, and then the stream goes
/// quiet. The agent naming its window is the other reliable sign.
enum AgentLaunchGate {
    /// How long the output must have settled before it is judged.
    static let quietInterval: TimeInterval = 0.45
    /// Before this, whatever arrived is the shell, not the agent.
    static let minimumElapsed: TimeInterval = 1.2
    /// A drawn screen weighs more than a prompt and an echoed command.
    static let minimumBytes = 1_500
    /// Quiet with too little output for this long: show whatever there is,
    /// an error message most likely.
    static let giveUpAfter: TimeInterval = 3.0
    /// Never keep the terminal covered longer than this.
    static let hardCap: TimeInterval = 10.0

    static func revealsAfterQuiet(elapsed: TimeInterval, bytes: Int) -> Bool {
        (elapsed >= minimumElapsed && bytes >= minimumBytes) || elapsed >= giveUpAfter
    }

    /// A title that carries the agent's name, set by the agent itself and
    /// not by the shell echoing the command line it is about to run (which
    /// also carries the name, as `claude --session-id …`).
    static func titleAnnouncesAgent(_ title: String, agentName: String, launchCommand: String?) -> Bool {
        let lowered = title.lowercased()
        guard lowered.contains(agentName.lowercased()) else { return false }
        if lowered.contains("--") { return false }
        if let launchCommand, lowered == launchCommand.lowercased() { return false }
        return true
    }
}

/// `TerminalView` that tells its owner when it gains keyboard focus. SwiftTerm
/// does not open its responder overrides, so focus is read off the window.
final class StudioTerminalView: TerminalView {
    var onFocus: (() -> Void)?
    var onCloseShortcut: (() -> Bool)?
    /// ⇧↩ should insert a newline in an agent prompt, not send the message.
    var onShiftReturn: (() -> Bool)?
    /// Any key typed, before the view sees it: a launch screen lifts on it.
    var onKeyDown: (() -> Void)?
    private var focusObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            guard let self, window.firstResponder === self else { return }
            self.onFocus?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }
}

/// One interactive shell inside a session pane, or the project's quick terminal.
///
/// Owns the PTY and the terminal view so both outlive SwiftUI re-renders and
/// survive switching sessions; the view is only re-parented.
final class TerminalPaneRuntime: NSObject, ObservableObject, LocalProcessDelegate, TerminalViewDelegate {
    let id: String
    let projectID: String
    let projectRoot: String
    let kind: PaneKind
    private(set) var launchCommand: String?

    @Published private(set) var title: String
    @Published private(set) var currentDirectory: String?
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var hasFocus = false
    /// False until the first shell is spawned: a pane that was never shown
    /// has not "exited", it simply has not started.
    @Published private(set) var hasStarted = false
    /// True from the moment an agent terminal starts until the agent has
    /// drawn its first screen: the pane shows a launch screen instead of the
    /// shell prompt and the command being typed into it.
    @Published private(set) var isLaunching = false
    /// Timestamps of the last output chunks. A working agent streams dozens
    /// per second; an idle one refreshes a status line now and then.
    ///
    /// Deliberately not `@Published`: output arrives dozens of times a second,
    /// and publishing each chunk redrew the pane chrome at that rate. Activity
    /// is read from here once a second by `StudioWorkspace`.
    private var recentOutput: [Date] = []
    private static let recentOutputCapacity = 24
    private static let workingChunkThreshold = 4

    /// Fires when the view becomes first responder, so the session can track
    /// which pane keyboard shortcuts act on.
    var onFocus: ((TerminalPaneRuntime) -> Void)?
    var onCloseShortcut: ((TerminalPaneRuntime) -> Void)?
    var onTitleChange: ((TerminalPaneRuntime) -> Void)?
    /// The shell moved to another folder (OSC 7).
    var onDirectoryChange: ((TerminalPaneRuntime) -> Void)?
    var onExit: ((TerminalPaneRuntime) -> Void)?

    private var process: LocalProcess?
    private var view: StudioTerminalView?
    private var fontSize: CGFloat
    private let defaultTitle: String
    private var launchWork: DispatchWorkItem?
    private var restartAfterExit = false
    private var launchStartedAt: Date?
    private var launchBytes = 0
    private var launchQuietWork: DispatchWorkItem?
    private var launchCapWork: DispatchWorkItem?
    /// Output before this date does not count as "working": a shell and an
    /// agent print a lot while starting, which is not the agent thinking.
    private(set) var activityMutedUntil: Date?

    init(
        id: String,
        projectID: String,
        projectRoot: String,
        kind: PaneKind,
        launchCommand: String?,
        initialTitle: String,
        fontSize: CGFloat
    ) {
        self.id = id
        self.projectID = projectID
        self.projectRoot = projectRoot
        self.kind = kind
        self.launchCommand = launchCommand
        self.defaultTitle = initialTitle
        self.title = initialTitle
        self.fontSize = fontSize
        super.init()
    }

    // MARK: - View

    /// Main thread only. Creating the view spawns the shell on first use.
    func terminalView() -> StudioTerminalView {
        if let view { return view }
        let created = StudioTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        created.optionAsMetaKey = false
        created.terminalDelegate = self
        TerminalStyling.apply(to: created, fontSize: fontSize)
        created.onFocus = { [weak self] in
            guard let self else { return }
            if !self.hasFocus { self.hasFocus = true }
            self.onFocus?(self)
        }
        created.onCloseShortcut = { [weak self] in
            guard let self, let onCloseShortcut = self.onCloseShortcut else { return false }
            onCloseShortcut(self)
            return true
        }
        // Backslash + Return is the newline escape every Claude Code build
        // understands, and a harmless line continuation in a shell.
        created.onShiftReturn = { [weak self] in
            guard let self, self.isRunning else { return false }
            self.send(text: "\\\r")
            return true
        }
        created.onKeyDown = { [weak self] in self?.revealTerminal() }
        view = created
        if process == nil { start() }
        return created
    }

    var hasView: Bool { view != nil }

    /// The agent this pane starts, for the launch screen.
    var agentName: String { defaultTitle }

    /// Whether the launch brings a conversation back rather than opening one.
    var launchResumesConversation: Bool {
        launchCommand?.contains("--resume") == true
    }

    func focus() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func markUnfocused() {
        if hasFocus { hasFocus = false }
    }

    func muteActivity(for seconds: TimeInterval) {
        activityMutedUntil = Date().addingTimeInterval(seconds)
    }

    /// True when output has been *streaming* recently: several chunks inside
    /// the window, past the startup noise. One stray refresh does not count.
    func isProducingOutput(within window: TimeInterval, now: Date = Date()) -> Bool {
        guard isRunning else { return false }
        if let activityMutedUntil, now < activityMutedUntil { return false }
        let recent = recentOutput.filter { now.timeIntervalSince($0) < window }
        return recent.count >= Self.workingChunkThreshold
    }

    /// Wipe the terminal and start over with a fresh shell (and a fresh agent
    /// conversation when `launchCommand` changed).
    func reset(launchCommand newCommand: String?) {
        launchCommand = newCommand
        muteActivity(for: 4)
        if isRunning {
            restartAfterExit = true
            terminate()
        } else {
            restart()
        }
    }

    func setFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        view?.font = TerminalStyling.font(size: size)
    }

    // MARK: - Process

    func start() {
        guard !isRunning else { return }
        LoginEnvironment.ensureResolved()
        let directory = FileManager.default.fileExists(atPath: projectRoot)
            ? projectRoot
            : FileManager.default.homeDirectoryForCurrentUser.path
        let proc = LocalProcess(delegate: self)
        process = proc
        exitCode = nil
        let shell = TerminalStyling.loginShell
        proc.startProcess(
            executable: shell,
            args: ["-l"],
            environment: TerminalStyling.environment(projectRoot: projectRoot),
            execName: nil,
            currentDirectory: directory
        )
        isRunning = proc.running
        hasStarted = true
        title = defaultTitle
        if let launchCommand, !launchCommand.isEmpty {
            if kind == .agent { beginLaunchScreen() }
            // Let the prompt appear first so the command reads as typed, the way
            // an iTerm profile's "send text at start" does.
            let work = DispatchWorkItem { [weak self] in
                self?.send(text: launchCommand + "\n")
            }
            launchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    // MARK: - Launch screen

    /// Cover the terminal until the agent has something to show. The cover
    /// lifts on the first sign of a ready agent (see `AgentLaunchGate`), on
    /// any key, when the process ends, and after a hard cap regardless.
    private func beginLaunchScreen() {
        launchStartedAt = Date()
        launchBytes = 0
        launchCapWork?.cancel()
        let cap = DispatchWorkItem { [weak self] in self?.revealTerminal() }
        launchCapWork = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentLaunchGate.hardCap, execute: cap)
        scheduleLaunchQuietCheck(after: AgentLaunchGate.giveUpAfter)
        if !isLaunching { isLaunching = true }
    }

    func revealTerminal() {
        guard isLaunching else { return }
        launchQuietWork?.cancel()
        launchQuietWork = nil
        launchCapWork?.cancel()
        launchCapWork = nil
        launchStartedAt = nil
        isLaunching = false
    }

    /// Re-armed by every chunk of output: when the stream has settled for a
    /// moment, ask the gate whether what arrived looks like a drawn screen.
    private func scheduleLaunchQuietCheck(after delay: TimeInterval) {
        launchQuietWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isLaunching, let started = self.launchStartedAt else { return }
            let elapsed = Date().timeIntervalSince(started)
            if AgentLaunchGate.revealsAfterQuiet(elapsed: elapsed, bytes: self.launchBytes) {
                self.revealTerminal()
            } else {
                self.scheduleLaunchQuietCheck(after: max(0.1, AgentLaunchGate.giveUpAfter - elapsed))
            }
        }
        launchQuietWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A fresh shell in the same pane, after the previous one exited.
    func restart() {
        guard !isRunning else { return }
        view?.getTerminal().resetToInitialState()
        if let view { view.setNeedsDisplay(view.bounds) }
        start()
    }

    func terminate() {
        launchWork?.cancel()
        launchWork = nil
        guard let process, process.running, process.shellPid > 0 else {
            isRunning = false
            return
        }
        let pid = process.shellPid
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let proc = self.process, proc.running else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    func send(text: String) {
        guard let process, process.running else { return }
        process.send(data: ArraySlice(Array(text.utf8)))
    }

    func clear() {
        // Same as ⌃L, but also drops the scrollback so it reads as a fresh pane.
        view?.getTerminal().resetToInitialState()
        if let view { view.setNeedsDisplay(view.bounds) }
        send(text: "\u{0C}")
    }

    // MARK: - LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.exitCode = ServerRuntime.normalizedProcessExitCode(exitCode)
            self.isRunning = false
            self.process = nil
            self.revealTerminal()
            if self.restartAfterExit {
                self.restartAfterExit = false
                self.restart()
                return
            }
            let code = self.exitCode.map(String.init) ?? "signal"
            self.view?.feed(text: "\r\n\u{1B}[2m[portly] shell exited (\(code))\u{1B}[0m\r\n")
            self.onExit?(self)
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view?.feed(byteArray: slice)
            self.recentOutput.append(Date())
            if self.recentOutput.count > Self.recentOutputCapacity {
                self.recentOutput.removeFirst(self.recentOutput.count - Self.recentOutputCapacity)
            }
            if self.isLaunching {
                self.launchBytes += slice.count
                self.scheduleLaunchQuietCheck(after: AgentLaunchGate.quietInterval)
            }
        }
    }

    func getWindowSize() -> winsize {
        guard let view else {
            return winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        }
        let terminal = view.getTerminal()
        return winsize(
            ws_row: UInt16(terminal.rows),
            ws_col: UInt16(terminal.cols),
            ws_xpixel: UInt16(view.frame.width),
            ws_ypixel: UInt16(view.frame.height)
        )
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process?.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let process, process.running, process.childfd >= 0 else { return }
        var size = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    /// Claude Code prefixes its title with an animated glyph (✳ ✶ ✻ …) while it
    /// works. The sidebar draws its own spinner, so keep only the words.
    static func cleanTitle(_ raw: String) -> String {
        let scalars = raw.unicodeScalars
        let start = scalars.firstIndex { CharacterSet.alphanumerics.contains($0) } ?? scalars.startIndex
        let cleaned = String(String.UnicodeScalarView(scalars[start...])).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        let trimmed = Self.cleanTitle(title)
        let next = trimmed.isEmpty ? defaultTitle : trimmed
        if isLaunching, AgentLaunchGate.titleAnnouncesAgent(title, agentName: defaultTitle, launchCommand: launchCommand) {
            // The agent names its window as it draws its first screen; give
            // that frame a beat to land before the cover lifts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.revealTerminal() }
        }
        guard next != self.title else { return }
        self.title = next
        onTitleChange?(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 sends a file URL; keep a plain path for the chrome. Shells
        // report the directory on every prompt, so only a real move publishes.
        var next = directory
        if let directory, let url = URL(string: directory), url.isFileURL {
            next = url.path
        }
        guard next != currentDirectory else { return }
        currentDirectory = next
        onDirectoryChange?(self)
    }

    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
