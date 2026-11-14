import AppKit
import PortlyCore
import SwiftUI

/// What a project window shows: one space at a time, picked from its rail.
enum ProjectWindowSpace: Hashable {
    /// The coding sessions, as tabs along the top.
    case code
    /// One of the project's servers and its terminal.
    case server(String)
}

/// The state of one project window: which space is on screen and which
/// session tab is selected. Lives as long as the window.
final class ProjectWindowModel: ObservableObject {
    let projectID: String
    @Published private(set) var space: ProjectWindowSpace = .code
    @Published private(set) var sessionID: String?
    weak var window: NSWindow?
    /// The strip as last seen, to find a closed session's neighbour.
    private var knownSessionIDs: [String] = []

    private var workspace: StudioWorkspace { StudioWorkspace.shared }

    init(projectID: String) {
        self.projectID = projectID
    }

    /// The selected session, or the one that took its place in the strip.
    func currentSession(in sessions: [TerminalSession]) -> TerminalSession? {
        sessions.first { $0.id == sessionID } ?? sessions.first
    }

    func showCode() {
        guard space != .code else { return }
        space = .code
        activate()
    }

    func showServer(_ serverID: String) {
        guard space != .server(serverID) else { return }
        space = .server(serverID)
        activate()
    }

    func selectSession(_ id: String) {
        guard workspace.session(id)?.projectID == projectID else { return }
        space = .code
        if sessionID != id { sessionID = id }
        activate()
    }

    /// ⌘1…⌘9: the session at that place in the strip.
    func selectSession(at index: Int) {
        let sessions = workspace.sessions(for: projectID)
        guard sessions.indices.contains(index) else { NSSound.beep(); return }
        selectSession(sessions[index].id)
    }

    /// A new session, opened at the right end of the strip.
    func newSession() {
        let session = workspace.createSession(projectID: projectID)
        selectSession(session.id)
    }

    /// Close a session; the one that slides into its place is shown.
    func closeSession(_ id: String) {
        let sessions = workspace.sessions(for: projectID)
        let next = SessionOrder.successor(afterRemoving: id, from: sessions)
        workspace.removeSession(id)
        if sessionID == id || sessionID == nil {
            sessionID = next
            activate()
        }
    }

    /// The sessions changed underneath (one closed from its last pane, from
    /// a menu): keep the selection on one that still exists, the one that
    /// slid into the closed one's place when there is one.
    func reconcile(sessionIDs: [String]) {
        defer { knownSessionIDs = sessionIDs }
        if let current = sessionID, sessionIDs.contains(current) { return }
        var next = sessionIDs.first
        if let current = sessionID, let index = knownSessionIDs.firstIndex(of: current), !sessionIDs.isEmpty {
            next = sessionIDs[min(index, sessionIDs.count - 1)]
        }
        guard next != sessionID else { return }
        sessionID = next
        activate()
    }

    /// Go where a destination points, inside this window.
    func show(_ selection: MainView.Selection) {
        switch selection {
        case .session(let id): selectSession(id)
        case .server(let id): showServer(id)
        case .project: showCode()
        case .resources, .ports, .terminal: break
        }
    }

    /// This window speaks for the keyboard commands and the agents: its
    /// project and, in the code space, its session become the active ones.
    /// Only while it is the key window, so typing in the main window is never
    /// redirected here.
    func activate() {
        let shownSession = space == .code
            ? currentSession(in: workspace.sessions(for: projectID))?.id
            : nil
        workspace.setWindowSession(shownSession, forProject: projectID)
        updateTitle()
        guard window?.isKeyWindow == true else { return }
        workspace.activeProjectID = projectID
        workspace.activeSessionID = shownSession
    }

    /// The project's name, with the session or server under it.
    func updateTitle() {
        guard let window else { return }
        let supervisor = Supervisor.shared
        let project = supervisor.projects.first { $0.id == projectID }
        let title = project?.name ?? "Project"
        if window.title != title { window.title = title }
        let subtitle: String
        switch space {
        case .code:
            subtitle = currentSession(in: workspace.sessions(for: projectID))?.name ?? "Code"
        case .server(let id):
            subtitle = supervisor.runtime(for: id)?.config.name ?? "Server"
        }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }
}

/// Opens, finds and closes the windows that hold a single project.
///
/// A project in its own window leaves the sidebar until the window closes.
/// Nothing about these windows is saved: AppKit is told not to restore them,
/// and the list of detached projects lives in memory, so a relaunch shows
/// every project back in the sidebar. Only each window's frame is
/// remembered, so a project reopens on the screen it was last moved to.
final class ProjectWindowCenter: NSObject, NSWindowDelegate {
    static let shared = ProjectWindowCenter()

    private static let identifierPrefix = "portly.project."
    private static let defaultSize = NSSize(width: 1120, height: 720)

    private var windows: [String: NSWindow] = [:]
    private var models: [String: ProjectWindowModel] = [:]

    // MARK: - Opening and closing

    /// Give the project a window of its own, showing `selection` when it is
    /// one of the project's sessions or servers, else its first session.
    func open(projectID: String, showing selection: MainView.Selection? = nil) {
        if windows[projectID] != nil {
            if let selection { route(selection) } else { bringToFront(projectID: projectID) }
            return
        }
        guard Supervisor.shared.projects.contains(where: { $0.id == projectID }) else { return }
        let workspace = StudioWorkspace.shared
        workspace.markDetached(projectID)

        let model = ProjectWindowModel(projectID: projectID)
        let root = ProjectWindowView(model: model)
            .environmentObject(Supervisor.shared)
            .font(PortlyTypography.body)
        let controller = NSHostingController(rootView: root)
        // The toolbar comes from SwiftUI; the title is set by the model so
        // it always reads "project — session" whatever the screen declares.
        controller.sceneBridgingOptions = [.toolbars]
        controller.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.identifier = NSUserInterfaceItemIdentifier(Self.identifierPrefix + projectID)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.setContentSize(Self.defaultSize)
        let autosaveName = "PortlyProjectWindow-\(projectID)"
        if !window.setFrameUsingName(autosaveName) {
            placeNewWindow(window)
        }
        window.setFrameAutosaveName(autosaveName)

        model.window = window
        windows[projectID] = window
        models[projectID] = model

        if let selection, workspace.projectID(of: selection) == projectID {
            model.show(selection)
        } else {
            model.reconcile(sessionIDs: workspace.sessions(for: projectID).map(\.id))
        }
        model.updateTitle()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Close the window: the project goes back to the sidebar. Its sessions
    /// and servers keep running.
    func close(projectID: String) {
        windows[projectID]?.performClose(nil)
    }

    /// Close the window and carry on in the main window where this one was:
    /// the same session (its focused terminal kept), or the same server.
    func returnToMainWindow(projectID: String) {
        guard let model = models[projectID] else { return }
        let workspace = StudioWorkspace.shared
        let place: MainView.Selection
        switch model.space {
        case .code:
            place = model.currentSession(in: workspace.sessions(for: projectID)).map { .session($0.id) }
                ?? .project(projectID)
        case .server(let id):
            place = .server(id)
        }
        close(projectID: projectID)
        // The close is synchronous: the project is back in the sidebar by
        // now, so the destination lands in the main window.
        workspace.navigate(to: place)
        WindowOpener.openMainWindow()
    }

    func bringToFront(projectID: String) {
        guard let window = windows[projectID] else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Send a destination to the window of the project it belongs to.
    /// False when that project has no window of its own.
    @discardableResult
    func route(_ selection: MainView.Selection) -> Bool {
        guard let projectID = StudioWorkspace.shared.projectID(of: selection),
              let model = models[projectID] else { return false }
        model.show(selection)
        bringToFront(projectID: projectID)
        return true
    }

    // MARK: - Lookup

    func model(for window: NSWindow?) -> ProjectWindowModel? {
        guard let raw = window?.identifier?.rawValue, raw.hasPrefix(Self.identifierPrefix) else { return nil }
        return models[String(raw.dropFirst(Self.identifierPrefix.count))]
    }

    /// True when the keyboard is in a project window rather than the main one.
    var isKeyWindowProjectWindow: Bool {
        model(for: NSApp.keyWindow) != nil
    }

    /// Whether the keyboard is in the window that shows this project: its
    /// own window when it has one, the main window otherwise.
    func keyWindowShows(projectID: String) -> Bool {
        if let model = model(for: NSApp.keyWindow) { return model.projectID == projectID }
        return !StudioWorkspace.shared.isDetached(projectID)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        model(for: notification.object as? NSWindow)?.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let model = model(for: window) else { return }
        let projectID = model.projectID
        windows.removeValue(forKey: projectID)
        models.removeValue(forKey: projectID)
        model.window = nil
        let workspace = StudioWorkspace.shared
        if workspace.activeSessionID.flatMap({ workspace.session($0)?.projectID }) == projectID {
            workspace.activeSessionID = nil
        }
        workspace.markReattached(projectID)
        // Once the close has played out, the hosted views go: nothing in a
        // closed window may hold on to a terminal the sidebar now shows. The
        // terminals themselves live on in their runtimes.
        DispatchQueue.main.async { window.contentViewController = nil }
    }

    // MARK: - Placement

    /// The first time a project gets a window: centred on the main window's
    /// screen, stepped down from any project window already open.
    private func placeNewWindow(_ window: NSWindow) {
        let main = NSApp.windows.first { $0.identifier?.rawValue.contains(WindowOpener.mainWindowID) == true }
        if let last = windows.values.first(where: \.isVisible) {
            let origin = last.frame.origin
            window.setFrameOrigin(NSPoint(x: origin.x + 28, y: origin.y - 28))
        } else if let screen = main?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = NSSize(
                width: min(window.frame.width, visible.width - 40),
                height: min(window.frame.height, visible.height - 40)
            )
            window.setFrame(
                NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
        } else {
            window.center()
        }
    }
}
