import AppKit
import PortlyCore
import SwiftUI

struct MainView: View {
    enum Selection: Hashable {
        case resources
        case ports
        case project(String)
        case server(String)
        case session(String)
    }

    @EnvironmentObject private var supervisor: Supervisor
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var appSelection = AppSelection.shared
    @ObservedObject private var workspace = StudioWorkspace.shared
    @StateObject private var agentSetup = AgentSetup()
    @StateObject private var systemAccess = SystemAccessStatus()
    @AppStorage("agentOnboardingDismissed") private var agentOnboardingDismissed = false
    @AppStorage("systemAccessDismissed") private var systemAccessDismissed = false
    @State private var selection: Selection?
    @State private var editingProject: Project?
    @State private var editingServer: EditingServer?
    @State private var addingProject = false
    @State private var runningTemporary = false
    @State private var search = ""
    @State private var doubleClickMonitor: Any?
    @State private var collapsedProjects: Set<String> = MainView.loadCollapsedProjects()
    @FocusState private var searchFocused: Bool

    private static let lastSelectionKey = "lastSelection"
    private static let collapsedProjectsKey = "collapsedProjects"

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if !agentOnboardingDismissed {
                            AgentOnboardingCard(setup: agentSetup) {
                                agentOnboardingDismissed = true
                            }
                        }
                        if !systemAccessDismissed, !systemAccess.isComplete {
                            SystemAccessCard(status: systemAccess) {
                                systemAccessDismissed = true
                            }
                        }
                    }
                }
                .projectDropTarget(currentProject)
                .overlay(alignment: .topTrailing) {
                    if let projectID = workspace.envPanelProjectID, let project = storedProject(projectID) {
                        EnvEditorPanel(project: project)
                            .id(project.id)
                            .padding(.top, 10)
                            .padding(.trailing, 12)
                    } else if workspace.quickTerminalVisible, let project = currentProject {
                        QuickTerminalOverlay(project: project)
                            .padding(.top, 10)
                            .padding(.trailing, 12)
                    }
                }
                .animation(Motion.banner, value: workspace.quickTerminalVisible)
                .animation(Motion.banner, value: workspace.envPanelProjectID)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                KeepAwakeToolbarButton()
            }
        }
        .onAppear {
            WindowOpener.opener = { openWindow(id: WindowOpener.mainWindowID) }
            agentSetup.refresh()
            systemAccess.refresh()
            applyPendingSelection()
            restoreLastSelection()
            syncWorkspaceContext()
            installDoubleClickMonitor()
            // Give the window a beat to appear before respawning every shell.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                workspace.reopenSessionsAtLaunchIfNeeded()
            }
        }
        .onDisappear {
            if let doubleClickMonitor { NSEvent.removeMonitor(doubleClickMonitor) }
            doubleClickMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemAccess.refresh()
        }
        .onChange(of: appSelection.pending) { applyPendingSelection() }
        .onChange(of: supervisor.revision) { clearFinishedTemporarySelection() }
        .onChange(of: selection) {
            syncWorkspaceContext()
            rememberSelection()
        }
        .onChange(of: workspace.pendingSelection) {
            guard let pending = workspace.pendingSelection else { return }
            selection = pending
            workspace.pendingSelection = nil
        }
        .sheet(isPresented: $addingProject) {
            ProjectForm(
                project: nil,
                takenColors: supervisor.projects.map(\.color)
            ) { name, root, icon, color in
                let project = supervisor.addProject(
                    name: name,
                    root: root,
                    icon: icon,
                    color: color
                )
                selection = .project(project.id)
            }
        }
        .sheet(isPresented: $runningTemporary) {
            TemporaryProcessForm { name, command, directory, port, healthURL, timeoutSeconds in
                let runtime = supervisor.runTemporary(
                    name: name,
                    command: command,
                    directory: directory,
                    port: port,
                    healthURL: healthURL,
                    timeoutSeconds: timeoutSeconds
                )
                selection = .server(runtime.id)
            }
        }
        .sheet(item: $editingProject) { project in
            ProjectForm(
                project: project,
                takenColors: supervisor.projects.filter { $0.id != project.id }.map(\.color)
            ) { name, root, icon, color in
                var updated = project
                updated.name = name
                updated.root = root
                updated.icon = icon
                updated.color = color
                supervisor.updateProject(updated)
            }
        }
        .sheet(item: $editingServer) { editing in
            ServerForm(
                server: editing.server,
                projectID: editing.projectID,
                projectName: editing.projectName,
                projectRoot: editing.projectRoot
            ) { result, memoryLimitMode, memoryLimitBytes in
                supervisor.updateProjectMemoryLimit(
                    projectID: editing.projectID,
                    mode: memoryLimitMode,
                    bytes: memoryLimitBytes
                )
                if let existing = editing.server, existing.id == result.id {
                    supervisor.updateServer(result)
                } else {
                    supervisor.addServer(projectID: editing.projectID, server: result)
                    selection = .server(result.id)
                }
            }
        }
        .font(PortlyTypography.body)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if !filteredTemporaryRuntimes.isEmpty {
                Section {
                    ForEach(filteredTemporaryRuntimes, id: \.id) { runtime in
                        ServerRow(runtime: runtime)
                            .tag(Selection.server(runtime.id))
                            .contextMenu { temporaryServerMenu(runtime) }
                    }
                } header: {
                    NucleoLabel("Temporary", icon: .timer)
                        .help("Supervised background jobs currently running with a timeout")
                }
            }

            ForEach(filteredSidebarProjects) { project in
                let sessions = workspace.sessions(for: project.id)
                let childCount = project.servers.count + sessions.count
                // A search is a request to see matches: never hide them.
                let isCollapsed = collapsedProjects.contains(project.id) && !SidebarSearch.isActive(search)
                Section {
                    ProjectHeader(
                        project: project,
                        childCount: childCount,
                        isCollapsed: isCollapsed
                    ) {
                        toggleCollapsed(project.id)
                    }
                    .tag(Selection.project(project.id))
                    .contextMenu {
                        if let project = storedProject(project.id) { projectMenu(project) }
                    }

                    if !isCollapsed {
                        ForEach(Array(project.servers.enumerated()), id: \.element.id) { index, server in
                            if let runtime = supervisor.runtime(for: server.id) {
                                SidebarTreeRow(isLast: index == childCount - 1) {
                                    ServerRow(runtime: runtime)
                                }
                                .tag(Selection.server(server.id))
                                .contextMenu {
                                    if let project = storedProject(project.id) {
                                        serverMenu(runtime, project: project)
                                    }
                                }
                            }
                        }

                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            SidebarTreeRow(isLast: project.servers.count + index == childCount - 1) {
                                SessionRow(session: session) {
                                    workspace.removeSession(session.id)
                                    if selection == .session(session.id) { selection = .project(session.projectID) }
                                }
                            }
                            .tag(Selection.session(session.id))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(Motion.state, value: collapsedProjects)
        .overlay {
            if showEmptySearch {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
        // Running projects float to the top, so rows change place on their own.
        // Letting them travel keeps the list readable instead of teleporting.
        .animation(Motion.reorder, value: runningSignature)
        .safeAreaInset(edge: .top, spacing: 0) { sidebarSearch }
        .safeAreaInset(edge: .bottom) { sidebarActions }
        .onExitCommand {
            if SidebarSearch.isActive(search) { search = "" }
        }
    }

    /// Changes exactly when the running/idle split changes, which is what drives
    /// the sidebar order — not on every uptime tick.
    private var runningSignature: String {
        supervisor.projects
            .map { projectIsRunning($0) ? "1" : "0" }
            .joined()
    }

    private var sidebarProjects: [Project] {
        supervisor.projects.enumerated()
            .sorted { lhs, rhs in
                let lhsIsRunning = projectIsRunning(lhs.element)
                let rhsIsRunning = projectIsRunning(rhs.element)

                if lhsIsRunning != rhsIsRunning {
                    return lhsIsRunning
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private var filteredSidebarProjects: [Project] {
        SidebarSearch.filterProjects(sidebarProjects, query: search)
    }

    private var filteredTemporaryRuntimes: [ServerRuntime] {
        supervisor.visibleTemporaryRuntimes.filter {
            SidebarSearch.matchesServer($0.config, query: search)
        }
    }

    private var showEmptySearch: Bool {
        SidebarSearch.isActive(search)
            && filteredTemporaryRuntimes.isEmpty
            && filteredSidebarProjects.isEmpty
    }

    /// Search returns truncated `Project` copies. Mutations and "open" must use
    /// the store value so a filter cannot delete sibling servers on save.
    private func storedProject(_ id: String) -> Project? {
        supervisor.projects.first { $0.id == id }
    }

    private func activateFirstMatch() {
        switch SidebarSearch.firstMatch(
            temporaryServers: supervisor.visibleTemporaryRuntimes.map(\.config),
            projects: sidebarProjects,
            query: search
        ) {
        case .server(let id):
            selection = .server(id)
        case .project(let id):
            selection = .project(id)
        case nil:
            break
        }
    }

    private func projectIsRunning(_ project: Project) -> Bool {
        project.servers.contains { server in
            supervisor.runtime(for: server.id)?.isRunning == true
        }
    }

    private func openProject(_ project: Project) {
        guard let url = project.servers
            .compactMap({ supervisor.runtime(for: $0.id)?.url })
            .first,
            let link = URL(string: url)
        else { return }

        NSWorkspace.shared.open(link)
    }

    private var sidebarSearch: some View {
        SidebarSearchField(
            text: $search,
            focused: $searchFocused,
            onSubmit: activateFirstMatch
        )
    }

    private var sidebarActions: some View {
        VStack(spacing: 6) {
            sidebarDestinationButton(
                title: "Resources",
                icon: .chartLine,
                selection: .resources,
                hint: "Shows live memory, smart diagnostics, safe fixes, and heavy processes inside or outside Portly"
            )

            sidebarDestinationButton(
                title: "View Ports",
                icon: .network,
                selection: .ports,
                hint: "Shows every listening TCP port on this Mac"
            )

            Button {
                runningTemporary = true
            } label: {
                NucleoLabel("Run Temporary…", icon: .timer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Run temporary process")
            .accessibilityHint("For small previews and one-off work that should not create a permanent project")

            Button {
                addingProject = true
            } label: {
                NucleoLabel("Add Project", icon: .plus)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Add project")

        }
        .font(PortlyTypography.bodyMedium)
        .padding(10)
        .background(.bar)
    }

    private func sidebarDestinationButton(
        title: String,
        icon: AppIcon,
        selection destination: Selection,
        hint: String
    ) -> some View {
        Button {
            selection = destination
        } label: {
            HStack {
                NucleoLabel(title, icon: icon)
                Spacer()
                NucleoIconView(.chevronRight, size: 10)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(self.selection == destination ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055))
        }
        .accessibilityHint(hint)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("New Coding Session") { startSession(in: project) }
        Button("Environment Files…") {
            selection = .project(project.id)
            workspace.toggleEnvPanel(projectID: project.id)
        }
        Button("Quick Terminal") {
            selection = .project(project.id)
            workspace.envPanelProjectID = nil
            workspace.quickTerminalVisible = true
        }
        Divider()
        Button("Start All") { supervisor.startProject(project.id) }
        Button("Stop All") { supervisor.stopProject(project.id) }
        if project.servers.contains(where: { supervisor.runtime(for: $0.id)?.url != nil }) {
            Button("Open in Browser") { openProject(project) }
        }
        Divider()
        Button("Add Server…") {
            editingServer = EditingServer(projectID: project.id, projectName: project.name, projectRoot: project.root, server: nil)
        }
        Button("Edit Project…") { editingProject = project }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSString(string: project.root).expandingTildeInPath)
        }
        Divider()
        Button("Remove Project") {
            workspace.removeSessions(inProject: project.id)
            supervisor.removeProject(id: project.id)
        }
    }

    private func startSession(in project: Project) {
        let session = workspace.createSession(projectID: project.id)
        selection = .session(session.id)
    }

    /// The project the detail area is about, for the quick terminal, drops and ⌘N.
    private var currentProject: Project? {
        switch selection {
        case .project(let id): return storedProject(id)
        case .session(let id): return workspace.session(id).flatMap { storedProject($0.projectID) }
        case .server(let id): return supervisor.project(containing: id)
        case .resources, .ports, nil: return nil
        }
    }

    // MARK: - Collapsed projects

    private static func loadCollapsedProjects() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedProjectsKey) ?? [])
    }

    private func toggleCollapsed(_ projectID: String) {
        if collapsedProjects.contains(projectID) {
            collapsedProjects.remove(projectID)
        } else {
            collapsedProjects.insert(projectID)
        }
        UserDefaults.standard.set(Array(collapsedProjects).sorted(), forKey: Self.collapsedProjectsKey)
    }

    // MARK: - Selection memory & sidebar double-click

    private func rememberSelection() {
        let value: String?
        switch selection {
        case .project(let id): value = "project:\(id)"
        case .session(let id): value = "session:\(id)"
        case .server(let id): value = "server:\(id)"
        case .resources: value = "resources"
        case .ports: value = "ports"
        case nil: value = nil
        }
        UserDefaults.standard.set(value, forKey: Self.lastSelectionKey)
    }

    private func restoreLastSelection() {
        guard selection == nil, let stored = UserDefaults.standard.string(forKey: Self.lastSelectionKey) else { return }
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "project": if let id = parts.last, storedProject(id) != nil { selection = .project(id) }
        case "session": if let id = parts.last, workspace.session(id) != nil { selection = .session(id) }
        case "server": if let id = parts.last, supervisor.runtime(for: id) != nil { selection = .server(id) }
        case "resources": selection = .resources
        case "ports": selection = .ports
        default: break
        }
    }

    /// The list selects on the first click as usual; the second click of a
    /// double-click acts on whatever is selected. Gestures on the rows would
    /// steal the first click from the list, so this watches the raw event.
    private func installDoubleClickMonitor() {
        guard doubleClickMonitor == nil else { return }
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2,
                  let window = event.window,
                  window.identifier?.rawValue.contains(WindowOpener.mainWindowID) == true,
                  let content = window.contentView,
                  let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                  Self.isInSidebar(hit)
            else { return event }
            DispatchQueue.main.async { handleSidebarDoubleClick() }
            return event
        }
    }

    /// True when the view sits in a table inside the split view's first pane.
    private static func isInSidebar(_ view: NSView) -> Bool {
        var sawTable = false
        var current: NSView? = view
        while let node = current {
            if node is NSTableView { sawTable = true }
            if let split = node as? NSSplitView {
                guard sawTable, let first = split.arrangedSubviews.first else { return false }
                return view.isDescendant(of: first)
            }
            current = node.superview
        }
        return false
    }

    private func handleSidebarDoubleClick() {
        switch selection {
        case .session(let id):
            workspace.renameRequest = id
        case .project(let id):
            if let project = storedProject(id) { openProject(project) }
        default:
            break
        }
    }

    private func syncWorkspaceContext() {
        workspace.activeProjectID = currentProject?.id
        if case .session(let id) = selection {
            workspace.activeSessionID = id
        } else {
            workspace.activeSessionID = nil
        }
    }

    @ViewBuilder
    private func serverMenu(_ runtime: ServerRuntime, project: Project) -> some View {
        if runtime.isRunning {
            Button("Stop") { runtime.stop() }
            Button("Restart") { runtime.restart() }
        } else {
            Button("Start") { runtime.start() }
        }
        Divider()
        if let url = runtime.url {
            Button("Open \(url)") {
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
            }
        }
        Button("Edit…") {
            editingServer = EditingServer(projectID: project.id, projectName: project.name, projectRoot: project.root, server: runtime.config)
        }
        Divider()
        Button("Remove Server") { supervisor.removeServer(id: runtime.id) }
    }

    @ViewBuilder
    private func temporaryServerMenu(_ runtime: ServerRuntime) -> some View {
        if runtime.isRunning {
            Button("Stop and Remove") { supervisor.removeServer(id: runtime.id) }
            Button("Restart") { runtime.restart() }
        } else if runtime.state == .failed {
            Button("Retry") { runtime.start() }
            Divider()
            Button("Remove") { supervisor.removeServer(id: runtime.id) }
        } else {
            Button("Run Again") { runtime.start() }
            Divider()
            Button("Remove") { supervisor.removeServer(id: runtime.id) }
        }
        if let url = runtime.url {
            Divider()
            Button("Open \(url)") {
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .resources:
            ResourceDashboard()
        case .ports:
            PortsView()
        case .server(let id):
            if let runtime = supervisor.runtime(for: id) {
                ServerDetail(
                    runtime: runtime,
                    onEdit: supervisor.temporaryRuntimeIDs.contains(id) ? nil : {
                        if let project = supervisor.project(containing: id) {
                            editingServer = EditingServer(
                                projectID: project.id,
                                projectName: project.name,
                                projectRoot: project.root,
                                server: runtime.config
                            )
                        }
                    }
                )
            } else {
                emptyDetail("This server no longer exists.")
            }
        case .session(let id):
            SessionView(sessionID: id)
        case .project(let id):
            if let project = supervisor.projects.first(where: { $0.id == id }) {
                ProjectDetail(project: project) {
                    editingServer = EditingServer(projectID: project.id, projectName: project.name, projectRoot: project.root, server: nil)
                } onEdit: {
                    editingProject = project
                } onSelectServer: { serverID in
                    selection = .server(serverID)
                } onNewSession: {
                    startSession(in: project)
                } onSelectSession: { sessionID in
                    selection = .session(sessionID)
                }
            } else {
                emptyDetail("This project no longer exists.")
            }
        case nil:
            emptyDetail(supervisor.projects.isEmpty && supervisor.visibleTemporaryRuntimes.isEmpty
                ? "Run a temporary process or add a project to get started."
                : "Select a server, or open a coding session on a project.")
        }
    }

    private func emptyDetail(_ message: String) -> some View {
        VStack(spacing: 8) {
            NucleoIconView(.bolt, size: 33)
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clearFinishedTemporarySelection() {
        guard case .server(let id) = selection,
              supervisor.temporaryRuntimeIDs.contains(id),
              supervisor.runtime(for: id)?.isRunning == false else { return }
        selection = nil
    }

    private func applyPendingSelection() {
        guard let pending = appSelection.pending else { return }
        selection = pending
        appSelection.pending = nil
    }

    struct EditingServer: Identifiable {
        let projectID: String
        let projectName: String
        let projectRoot: String
        let server: ServerConfig?
        var id: String { (server?.id ?? "new") + projectID }
    }
}

// MARK: - Sidebar rows

private struct ProjectHeader: View {
    let project: Project
    let childCount: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            NucleoIconView(LegacyProjectIcons.resolve(project.icon), size: 12)
                .foregroundStyle(Color(hex: project.color))
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(hex: project.color).opacity(0.12))
                }
            Text(project.name)
                .font(PortlyTypography.project)
                .lineLimit(1)
            Spacer()
            if childCount > 0 {
                if isCollapsed {
                    Text("\(childCount)")
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .transition(.opacity)
                }
                Button(action: onToggle) {
                    NucleoIconView(.chevronDown, size: 9)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: 20, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show servers and sessions" : "Hide servers and sessions")
                .accessibilityLabel(isCollapsed ? "Expand \(project.name)" : "Collapse \(project.name)")
                .onHover { hovering = $0 }
            }
        }
        .padding(.vertical, 2)
        .animation(Motion.state, value: isCollapsed)
    }
}

/// Indents a child row and draws the tree guide that ties it to the project
/// icon above: a vertical rail, a short tick, and a corner on the last row.
private struct SidebarTreeRow<Content: View>: View {
    let isLast: Bool
    @ViewBuilder let content: Content

    private let railX: CGFloat = 10
    private let tick: CGFloat = 7

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                Path { path in
                    let midY = proxy.size.height / 2
                    // Overshoot the row so consecutive rails meet.
                    path.move(to: CGPoint(x: railX, y: -6))
                    path.addLine(to: CGPoint(x: railX, y: isLast ? midY : proxy.size.height + 6))
                    path.move(to: CGPoint(x: railX, y: midY))
                    path.addLine(to: CGPoint(x: railX + tick, y: midY))
                }
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .frame(width: railX + tick + 6)
            .accessibilityHidden(true)
            content
        }
    }
}

private struct ServerRow: View {
    @ObservedObject var runtime: ServerRuntime

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: runtime.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(runtime.config.name)
                    .font(PortlyTypography.bodyMedium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let port = runtime.effectivePort {
                        Text("localhost:\(String(port))")
                            .foregroundStyle(runtime.portFallback == nil ? Color.secondary : Color.orange)
                            .help(runtime.portFallback.map { "Port \($0.requestedPort) was busy, running on \($0.usedPort)" } ?? "")
                    }
                    ForEach(runtime.extraPorts, id: \.self) { port in
                        Text(":\(String(port))")
                            .help("Also listening on port \(port)")
                    }
                    if let job = runtime.temporaryJobStatus {
                        Text(jobLabel(job))
                    }
                    if let metrics = runtime.processMetrics {
                        Spacer(minLength: 4)
                        NucleoIconView(.memory, size: 11)
                            .foregroundStyle(metrics.memoryPressure.color)
                            .help(
                                "Footprint: \(memoryText(metrics)) — \(metrics.memoryPressure.label). "
                                    + "Open the server for full resource details."
                            )
                            .accessibilityLabel(
                                "Memory footprint \(memoryText(metrics)), \(metrics.memoryPressure.label) use"
                            )
                    }
                }
                .font(PortlyTypography.metadata)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let startedAt = runtime.startedAt, runtime.isRunning {
                Text(startedAt.compactUptime)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
    }

    private func memoryText(_ metrics: ProcessMetrics) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(metrics.memoryBytes), countStyle: .memory)
    }

    private func jobLabel(_ job: TemporaryJobStatus) -> String {
        switch job.state {
        case .running: return "timeout \(TemporaryTimeout.display(job.timeoutSeconds))"
        case .succeeded: return "succeeded"
        case .failed: return job.exitCode.map { "failed (exit \($0))" } ?? "failed"
        case .timedOut: return "timed out"
        case .stopped: return "stopped"
        }
    }
}

private struct SessionRow: View {
    let session: TerminalSession
    let onClose: () -> Void

    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let activity = workspace.activity(for: session)
        let focused = session.focusedPaneID.flatMap { workspace.existingRuntime(paneID: $0) }
        HStack(spacing: 8) {
            NucleoIconView(session.panes.first?.kind == .agent ? workspace.config.defaultAgent.iconID : AppIcon.terminal.rawValue, size: 12)
                .foregroundStyle(activity == .idle ? Color.secondary : Color.accentColor)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    TextField("Session name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(PortlyTypography.bodyMedium)
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: nameFocused) { if !nameFocused, editing { commit() } }
                } else {
                    Text(session.name)
                        .font(PortlyTypography.bodyMedium)
                        .lineLimit(1)
                        .help("Double-click to rename")
                }
                Text(subtitle(focusedTitle: focused?.title))
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // A spinner while the agent works; a dot once it has finished and
            // you have not looked yet. Nothing when there is nothing to tell.
            switch activity {
            case .working:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .transition(.opacity)
                    .accessibilityLabel("Working")
            case .finished:
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.4)))
                    .accessibilityLabel("Finished, not seen yet")
            case .idle:
                EmptyView()
            }
        }
        .padding(.vertical, 1)
        .animation(Motion.state, value: activity)
        .onChange(of: workspace.renameRequest) {
            guard workspace.renameRequest == session.id else { return }
            workspace.renameRequest = nil
            beginRename()
        }
        .contextMenu {
            Button("Rename…", action: beginRename)
            Divider()
            Button("Split Right") { workspace.split(sessionID: session.id, axis: .horizontal) }
            Button("Split Down") { workspace.split(sessionID: session.id, axis: .vertical) }
            Divider()
            Button("Close Session", action: onClose)
        }
    }

    private func beginRename() {
        draft = session.name
        editing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commit() {
        workspace.renameSession(session.id, to: draft)
        editing = false
    }

    private func subtitle(focusedTitle: String?) -> String {
        let count = session.panes.count
        let panes = count == 1 ? "1 terminal" : "\(count) terminals"
        if let focusedTitle, !focusedTitle.isEmpty {
            return "\(focusedTitle) · \(panes)"
        }
        return panes
    }
}

// MARK: - Project detail

private struct ProjectDetail: View {
    let project: Project
    let onAddServer: () -> Void
    let onEdit: () -> Void
    let onSelectServer: (String) -> Void
    let onNewSession: () -> Void
    let onSelectSession: (String) -> Void

    @EnvironmentObject private var supervisor: Supervisor
    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var envFiles: [EnvFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: project.color).opacity(0.14))
                    NucleoIconView(LegacyProjectIcons.resolve(project.icon), size: 22)
                        .foregroundStyle(Color(hex: project.color))
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(PortlyTypography.title)
                    Text(NSString(string: project.root).abbreviatingWithTildeInPath)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(action: onNewSession) {
                    NucleoLabel("New Session", icon: .sparkle, size: 12)
                }
                .buttonStyle(.borderedProminent)
                .help("Open a coding session with \(workspace.config.defaultAgent.shortName) (⌘N)")
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sessionsSection
                    serversSection
                    environmentSection
                    dropSection
                }
                .padding(16)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    supervisor.startProject(project.id)
                } label: {
                    NucleoLabel("Start All", icon: .play)
                }
                .help("Start every server in this project")

                Button {
                    supervisor.stopProject(project.id)
                } label: {
                    NucleoLabel("Stop All", icon: .stop)
                }
                .help("Stop every server in this project")

                Button(action: onAddServer) {
                    NucleoLabel("Add Server", icon: .plus)
                }

                Button {
                    workspace.toggleEnvPanel(projectID: project.id)
                } label: {
                    NucleoLabel("Environment", icon: .key)
                }
                .help("Edit the project's .env files (⇧⌘E)")

                Button {
                    workspace.toggleQuickTerminal()
                } label: {
                    NucleoLabel("Quick Terminal", icon: .terminalSquare)
                }
                .help("Toggle the project's quick terminal (⌘J)")

                Button(action: onEdit) {
                    NucleoLabel("Edit Project", icon: .sliders)
                }
            }
        }
        .navigationTitle(project.name)
        .onAppear(perform: refreshEnv)
        .onChange(of: workspace.envPanelProjectID) { refreshEnv() }
    }

    private func refreshEnv() {
        envFiles = EnvFile.scan(root: project.root)
    }

    // MARK: Sections

    private func sectionHeader(_ title: String, icon: AppIcon, trailing: (() -> AnyView)? = nil) -> some View {
        HStack(spacing: 7) {
            NucleoIconView(icon, size: 12)
                .foregroundStyle(.secondary)
            Text(title)
                .font(PortlyTypography.bodyMedium)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing() }
        }
    }

    private var sessionsSection: some View {
        let sessions = workspace.sessions(for: project.id)
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Coding sessions", icon: .chats)
            if sessions.isEmpty {
                card {
                    HStack(spacing: 12) {
                        NucleoIconView(workspace.config.defaultAgent.iconID, size: 20)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No session yet")
                                .font(PortlyTypography.bodyMedium)
                            Text("A session is a set of terminals on this project. New ones start \(workspace.config.defaultAgent.shortName) at the root.")
                                .font(PortlyTypography.metadata)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Start coding", action: onNewSession)
                            .controlSize(.small)
                    }
                }
            } else {
                card {
                    VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            sessionLine(session)
                            if index < sessions.count - 1 { Divider().padding(.leading, 30) }
                        }
                    }
                }
            }
        }
    }

    private func sessionLine(_ session: TerminalSession) -> some View {
        let live = workspace.isLive(session)
        let activity = workspace.activity(for: session)
        return HStack(spacing: 10) {
            NucleoIconView(session.panes.first?.kind == .agent ? workspace.config.defaultAgent.iconID : AppIcon.terminal.rawValue, size: 13)
                .foregroundStyle(live ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(PortlyTypography.bodyMedium)
                Text(session.panes.map { $0.title ?? "Terminal" }.joined(separator: " · "))
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if activity == .working {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            }
            Text(activity == .working ? "Agent working…" : activity == .finished ? "Done" : live ? "Live" : "Idle")
                .font(PortlyTypography.label)
                .foregroundStyle(activity == .idle && !live ? Color.secondary : Color.accentColor)
            Button {
                onSelectSession(session.id)
            } label: {
                NucleoIconView(.arrowUpRight, size: 11)
            }
            .buttonStyle(.borderless)
            .help("Open this session")
            .accessibilityLabel("Open \(session.name)")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onSelectSession(session.id) }
    }

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Servers", icon: .server)
            if project.servers.isEmpty {
                card {
                    HStack(spacing: 12) {
                        Text("No servers in this project yet.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Server…", action: onAddServer)
                            .controlSize(.small)
                    }
                }
            } else {
                card {
                    VStack(spacing: 0) {
                        ForEach(Array(project.servers.enumerated()), id: \.element.id) { index, server in
                            if let runtime = supervisor.runtime(for: server.id) {
                                ProjectServerRow(runtime: runtime) { onSelectServer(server.id) }
                                if index < project.servers.count - 1 { Divider().padding(.leading, 30) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Environment files", icon: .key) {
                AnyView(
                    Button("Open editor") {
                        workspace.toggleEnvPanel(projectID: project.id)
                    }
                    .buttonStyle(.plain)
                    .font(PortlyTypography.body)
                    .foregroundStyle(Color.accentColor)
                )
            }
            card {
                if envFiles.isEmpty {
                    HStack {
                        Text("No .env files at the root. The editor can create one.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(envFiles) { file in
                            Button {
                                workspace.toggleEnvPanel(projectID: project.id)
                            } label: {
                                HStack(spacing: 6) {
                                    NucleoIconView(file.isExample ? .file : .key, size: 11)
                                        .foregroundStyle(file.isExample ? Color.secondary : Color(hex: project.color))
                                    Text(file.name)
                                        .font(.system(size: 12, design: .monospaced))
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(file.name)")
                        }
                    }
                }
            }
        }
    }

    private var dropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Drop zone", icon: .dropZone)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .foregroundStyle(Color.primary.opacity(0.18))
                VStack(spacing: 6) {
                    NucleoIconView(.importFiles, size: 22)
                        .foregroundStyle(.secondary)
                    Text("Drop images, videos or any file anywhere on this screen")
                        .font(PortlyTypography.body)
                    Text("They are copied to the project root, then you can hand the list to the agent.")
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ProjectServerRow: View {
    @ObservedObject var runtime: ServerRuntime
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: runtime.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.config.name)
                    .font(PortlyTypography.bodyMedium)
                Text(runtime.config.command)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(runtime.state.label)
                .font(PortlyTypography.label)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(Motion.state, value: runtime.state)
            StartStopButton(runtime: runtime)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onSelect)
    }
}
