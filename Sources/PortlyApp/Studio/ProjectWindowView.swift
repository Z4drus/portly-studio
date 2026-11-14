import AppKit
import PortlyCore
import SwiftUI

/// A project on its own, in a window you can put on any screen: a rail of
/// icons on the left (the code, then each server), the sessions as thin tabs
/// along the top, and the same toolbar as in the main window.
///
/// Like `SessionView`, the view that declares the toolbar observes as little
/// as it can, so the bar is not rebuilt on every terminal title or activity
/// change.
struct ProjectWindowView: View {
    @ObservedObject var model: ProjectWindowModel

    @EnvironmentObject private var supervisor: Supervisor
    @ObservedObject private var gitCenter = GitCenter.shared
    @ObservedObject private var talvoPresence = TalvoCenter.shared.presence

    private var project: Project? {
        supervisor.projects.first { $0.id == model.projectID }
    }

    var body: some View {
        Group {
            if let project {
                ProjectWindowBody(model: model, project: project)
            } else {
                missingProject
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            if let project, talvoPresence.isConfigured {
                ToolbarItem(placement: .navigation) {
                    TalvoToolbarButton(project: project)
                        .id(project.id)
                }
            }
            if let root = project?.root, gitCenter.isRepository(root: root) {
                ToolbarItem(placement: .primaryAction) {
                    GitToolbarButton(projectRoot: root)
                        .id(root)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                KeepAwakeToolbarButton()
            }
        }
    }

    private var missingProject: some View {
        VStack(spacing: 10) {
            NucleoIconView(.bolt, size: 30)
                .foregroundStyle(.tertiary)
            Text("This project no longer exists.")
                .foregroundStyle(.secondary)
            Button("Close Window") { ProjectWindowCenter.shared.close(projectID: model.projectID) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Body

private struct ProjectWindowBody: View {
    @ObservedObject var model: ProjectWindowModel
    let project: Project

    @EnvironmentObject private var supervisor: Supervisor
    @ObservedObject private var workspace = StudioWorkspace.shared
    @ObservedObject private var talvoPresence = TalvoCenter.shared.presence
    @State private var editingServer: MainView.EditingServer?

    private var sessionIDs: [String] {
        workspace.sessions(for: project.id).map(\.id)
    }

    /// What the window title is made of, to refresh it when one changes.
    private var titleKey: String {
        let session = model.currentSession(in: workspace.sessions(for: project.id))?.name ?? ""
        return [project.name, session].joined(separator: "\u{1F}")
    }

    var body: some View {
        HStack(spacing: 0) {
            ProjectRail(
                model: model,
                project: project,
                onAddServer: {
                    editingServer = MainView.EditingServer(
                        projectID: project.id,
                        projectName: project.name,
                        projectRoot: project.root,
                        server: nil
                    )
                },
                onEditServer: edit
            )
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { talvoPanel }
                .animation(Motion.banner, value: workspace.talvoPanelProjectID)
                .overlay(alignment: .topTrailing) { cornerPanel }
                .animation(Motion.banner, value: workspace.quickTerminalProjectID)
                .animation(Motion.banner, value: workspace.envPanelProjectID)
        }
        .projectDropTarget(project)
        .onChange(of: sessionIDs, initial: true) { _, ids in
            model.reconcile(sessionIDs: ids)
        }
        .onChange(of: project.servers.map(\.id)) { _, ids in
            if case .server(let id) = model.space, !ids.contains(id) { model.showCode() }
        }
        .onChange(of: titleKey) { model.updateTitle() }
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
                    model.showServer(result.id)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.space {
        case .code:
            CodeSpace(model: model)
        case .server(let id):
            if let runtime = supervisor.runtime(for: id) {
                ServerDetail(runtime: runtime) { edit(runtime) }
                    .id(id)
            } else {
                VStack(spacing: 8) {
                    NucleoIconView(.server, size: 28)
                        .foregroundStyle(.tertiary)
                    Text("This server no longer exists.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var talvoPanel: some View {
        if talvoPresence.isConfigured,
           workspace.talvoPanelProjectID == project.id,
           let talvoID = workspace.talvoProjectID(for: project.id) {
            TalvoPanel(project: project, talvoProjectID: talvoID)
                .id(talvoID)
                .padding(10)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
    }

    /// The env editor and the quick terminal share the top-right corner.
    @ViewBuilder
    private var cornerPanel: some View {
        if workspace.envPanelProjectID == project.id {
            EnvEditorPanel(project: project)
                .id(project.id)
                .padding(.top, 10)
                .padding(.trailing, 12)
        } else if workspace.quickTerminalProjectID == project.id {
            QuickTerminalOverlay(project: project)
                .padding(.top, 10)
                .padding(.trailing, 12)
        }
    }

    private func edit(_ runtime: ServerRuntime) {
        editingServer = MainView.EditingServer(
            projectID: project.id,
            projectName: project.name,
            projectRoot: project.root,
            server: runtime.config
        )
    }
}

// MARK: - Code space

/// The sessions: the tab strip, and the selected one's terminals on black
/// right under it, so the active tab and its terminals read as one piece.
private struct CodeSpace: View {
    @ObservedObject var model: ProjectWindowModel

    @ObservedObject private var workspace = StudioWorkspace.shared

    var body: some View {
        let sessions = workspace.sessions(for: model.projectID)
        VStack(spacing: 0) {
            SessionTabStrip(model: model)
            if let session = model.currentSession(in: sessions) {
                // A new identity per session: its terminals are re-parented,
                // the session becomes the active one and its pane gets focus.
                SessionView(sessionID: session.id, showsSessionBar: false)
                    .id(session.id)
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: TerminalTheme.background))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            NucleoIconView(workspace.config.defaultAgent.iconID, size: 26)
                .foregroundStyle(Color.accentColor)
            Text("No session yet")
                .font(PortlyTypography.bodyMedium)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground))
            Text("A session is a set of terminals on this project. New ones start \(workspace.config.defaultAgent.shortName) at the root.")
                .font(PortlyTypography.metadata)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                model.newSession()
            } label: {
                NucleoLabel("New Session", icon: .plus, size: 11)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Open a coding session (⌘N)")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rail

/// The window's only sidebar: icons, no labels to read. The project's mark
/// at the top, then the code, then one entry per server with its state and
/// port, and the way back to the main window at the bottom.
private struct ProjectRail: View {
    @ObservedObject var model: ProjectWindowModel
    let project: Project
    let onAddServer: () -> Void
    let onEditServer: (ServerRuntime) -> Void

    @EnvironmentObject private var supervisor: Supervisor
    @ObservedObject private var workspace = StudioWorkspace.shared

    static let width: CGFloat = 56

    var body: some View {
        VStack(spacing: 6) {
            projectMark
                .padding(.bottom, 4)

            RailButton(
                isSelected: model.space == .code,
                help: "Code: the coding sessions",
                action: model.showCode
            ) {
                RailGlyph(icon: AppIcon.code.rawValue, caption: "Code", isSelected: model.space == .code) {
                    codeBadge
                }
            }

            if !project.servers.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 22, height: 1)
                    .padding(.vertical, 3)
                    .accessibilityHidden(true)
            }

            ForEach(project.servers) { server in
                if let runtime = supervisor.runtime(for: server.id) {
                    ServerRailButton(runtime: runtime, isSelected: model.space == .server(server.id)) {
                        model.showServer(server.id)
                    }
                    .contextMenu { serverMenu(runtime) }
                }
            }

            RailIconButton(icon: .plus, help: "Add a server to \(project.name)", action: onAddServer)

            Spacer(minLength: 8)

            RailIconButton(icon: .arrowDownLeft, help: "Back to the sidebar (closes this window)") {
                ProjectWindowCenter.shared.close(projectID: project.id)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    private var projectMark: some View {
        NucleoIconView(LegacyProjectIcons.resolve(project.icon), size: 13)
            .foregroundStyle(Color(hex: project.color))
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: project.color).opacity(0.14))
            }
            .help("\(project.name) · \(NSString(string: project.root).abbreviatingWithTildeInPath)")
            .accessibilityLabel(project.name)
    }

    /// News from a session you are not looking at: a spinner while one
    /// works, a dot once one has finished.
    @ViewBuilder
    private var codeBadge: some View {
        let sessions = workspace.sessions(for: project.id)
        let states = sessions.map { workspace.activity(for: $0) }
        if model.space != .code, states.contains(.working) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: 8, height: 8)
                .accessibilityLabel("A session is working")
        } else if model.space != .code, states.contains(.finished) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .accessibilityLabel("A session has finished")
        }
    }

    @ViewBuilder
    private func serverMenu(_ runtime: ServerRuntime) -> some View {
        if runtime.isRunning {
            Button("Stop") { runtime.stop() }
            Button("Restart") { runtime.restart() }
        } else {
            Button("Start") { runtime.start() }
        }
        if let url = runtime.url {
            Divider()
            Button("Open \(url)") {
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
            }
        }
        Divider()
        Button("Edit…") { onEditServer(runtime) }
    }
}

/// A rail entry: a rounded tile that fills in when its space is on screen.
private struct RailButton<Label: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(width: 44, height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.15)
                                : Color.primary.opacity(hovering ? 0.06 : 0)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.state, value: isSelected)
        .help(help)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// An icon over a tiny caption, with a badge in the icon's corner.
private struct RailGlyph<Badge: View>: View {
    let icon: String
    let caption: String
    let isSelected: Bool
    var captionIsMonospaced = false
    @ViewBuilder let badge: Badge

    var body: some View {
        VStack(spacing: 3) {
            NucleoIconView(icon, size: 14)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 18, height: 18)
                .overlay(alignment: .bottomTrailing) {
                    badge.offset(x: 4, y: 3)
                }
            Text(caption)
                .font(captionIsMonospaced
                    ? .system(size: 9, weight: .medium, design: .monospaced)
                    : .system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 42)
        }
    }
}

/// A server in the rail: its state as a dot on the icon, its port under it.
private struct ServerRailButton: View {
    @ObservedObject var runtime: ServerRuntime
    let isSelected: Bool
    let action: () -> Void

    private var caption: String {
        runtime.effectivePort.map { ":\(String($0))" } ?? runtime.config.name
    }

    private var help: String {
        var parts = [runtime.config.name, runtime.state.label]
        if let port = runtime.effectivePort { parts.append("localhost:\(String(port))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        RailButton(isSelected: isSelected, help: help, action: action) {
            RailGlyph(
                icon: AppIcon.server.rawValue,
                caption: caption,
                isSelected: isSelected,
                captionIsMonospaced: runtime.effectivePort != nil
            ) {
                StatusDot(state: runtime.state, size: 6)
            }
        }
        .accessibilityLabel("\(runtime.config.name), \(runtime.state.label)")
    }
}

/// A small action at the edge of the rail.
private struct RailIconButton: View {
    let icon: AppIcon
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            NucleoIconView(icon, size: 11)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 30, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}
