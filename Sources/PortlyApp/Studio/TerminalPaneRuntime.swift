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

/// `TerminalView` that tells its owner when it gains keyboard focus. SwiftTerm
/// does not open its responder overrides, so focus is read off the window.
final class StudioTerminalView: TerminalView {
    var onFocus: (() -> Void)?
    var onCloseShortcut: (() -> Bool)?
    /// ⇧↩ should insert a newline in an agent prompt, not send the message.
    var onShiftReturn: (() -> Bool)?
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
    /// Bumped whenever output arrives, so "activity" indicators can animate.
    @Published private(set) var lastOutputAt: Date?
    /// Timestamps of the last output chunks. A working agent streams dozens
    /// per second; an idle one refreshes a status line now and then.
    private var recentOutput: [Date] = []
    private static let recentOutputCapacity = 24
    private static let workingChunkThreshold = 4

    /// Fires when the view becomes first responder, so the session can track
    /// which pane keyboard shortcuts act on.
    var onFocus: ((TerminalPaneRuntime) -> Void)?
    var onCloseShortcut: ((TerminalPaneRuntime) -> Void)?
    var onTitleChange: ((TerminalPaneRuntime) -> Void)?
    var onExit: ((TerminalPaneRuntime) -> Void)?

    private var process: LocalProcess?
    private var view: StudioTerminalView?
    private var fontSize: CGFloat
    private let defaultTitle: String
    private var launchWork: DispatchWorkItem?
    private var restartAfterExit = false
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
        created.terminalDelegate = self
        TerminalStyling.apply(to: created, fontSize: fontSize)
        created.onFocus = { [weak self] in
            guard let self else { return }
            self.hasFocus = true
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
        view = created
        if process == nil { start() }
        return created
    }

    var hasView: Bool { view != nil }

    func focus() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func markUnfocused() {
        hasFocus = false
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
        title = defaultTitle
        if let launchCommand, !launchCommand.isEmpty {
            // Let the prompt appear first so the command reads as typed, the way
            // an iTerm profile's "send text at start" does.
            let work = DispatchWorkItem { [weak self] in
                self?.send(text: launchCommand + "\n")
            }
            launchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
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
            let now = Date()
            self.lastOutputAt = now
            self.recentOutput.append(now)
            if self.recentOutput.count > Self.recentOutputCapacity {
                self.recentOutput.removeFirst(self.recentOutput.count - Self.recentOutputCapacity)
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
        guard next != self.title else { return }
        self.title = next
        onTitleChange?(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else {
            currentDirectory = nil
            return
        }
        // OSC 7 sends a file URL; keep a plain path for the chrome.
        if let url = URL(string: directory), url.isFileURL {
            currentDirectory = url.path
        } else {
            currentDirectory = directory
        }
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
