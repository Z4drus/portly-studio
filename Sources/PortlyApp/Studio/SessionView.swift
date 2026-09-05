import AppKit
import PortlyCore
import SwiftUI

/// A coding session: one to five terminals, split any way you like.
struct SessionView: View {
    let sessionID: String

    @ObservedObject private var workspace = StudioWorkspace.shared
    @EnvironmentObject private var supervisor: Supervisor
    @State private var renaming = false
    @State private var draftName = ""
    @State private var showingHelp = false
    @FocusState private var nameFocused: Bool

    private var session: TerminalSession? { workspace.session(sessionID) }

    var body: some View {
        if let session {
            content(session)
        } else {
            VStack(spacing: 8) {
                NucleoIconView(.terminal, size: 30)
                    .foregroundStyle(.tertiary)
                Text("This session no longer exists.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ session: TerminalSession) -> some View {
        let project = workspace.project(for: session)
        return VStack(spacing: 0) {
            sessionBar(session, project: project)
            Divider()
            SplitLayoutView(
                layout: session.layout,
                zoomedPaneID: session.zoomedPaneID,
                onRatioChange: { splitID, ratio in
                    workspace.setRatio(sessionID: session.id, splitID: splitID, ratio: ratio)
                },
                leaf: { pane in
                    AnyView(
                        PaneView(
                            session: session,
                            pane: pane,
                            runtime: workspace.runtime(for: pane, in: session),
                            isFocused: session.focusedPaneID == pane.id,
                            isZoomed: session.zoomedPaneID == pane.id,
                            canSplit: workspace.canAddPane(to: session.id)
                        )
                    )
                }
            )
            .padding(8)
            .animation(Motion.paneSwap, value: session.layout.paneIDs)
            .animation(Motion.paneSwap, value: session.zoomedPaneID)
        }
        .toolbar { toolbarContent(session) }
        .navigationTitle(session.name)
        .navigationSubtitle(project?.name ?? "")
        .onAppear {
            workspace.activeSessionID = session.id
            workspace.activeProjectID = session.projectID
            focusCurrentPane(session)
        }
        .onDisappear {
            if workspace.activeSessionID == session.id {
                workspace.activeSessionID = nil
            }
        }
    }

    private func focusCurrentPane(_ session: TerminalSession) {
        guard let id = session.focusedPaneID ?? session.panes.first?.id else { return }
        DispatchQueue.main.async {
            workspace.existingRuntime(paneID: id)?.focus()
        }
    }

    // MARK: - Session bar

    private func sessionBar(_ session: TerminalSession, project: Project?) -> some View {
        HStack(spacing: 10) {
            if let project {
                NucleoIconView(LegacyProjectIcons.resolve(project.icon), size: 13)
                    .foregroundStyle(Color(hex: project.color))
            }

            if renaming {
                TextField("Session name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(PortlyTypography.bodyMedium)
                    .focused($nameFocused)
                    .frame(maxWidth: 240)
                    .onSubmit { commitRename(session) }
                    .onExitCommand { renaming = false }
            } else {
                Text(session.name)
                    .font(PortlyTypography.bodyMedium)
                    .onTapGesture(count: 2) { beginRename(session) }
                    .help("Double-click to rename")
            }

            Text("\(session.panes.count)/\(workspace.config.maxPanesPerSession) terminals")
                .font(PortlyTypography.metadata)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if session.zoomedPaneID != nil {
                Text("ZOOMED")
                    .font(PortlyTypography.label)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .transition(.opacity)
            }

            Spacer()

            HStack(spacing: 4) {
                barButton(.textSmaller, help: "Smaller text (⌘−)") {
                    workspace.adjustFontSize(sessionID: session.id, by: -1)
                }
                Text("\(Int(workspace.fontSize(for: session)))")
                    .font(PortlyTypography.metric)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .monospacedDigit()
                barButton(.textBigger, help: "Bigger text (⌘+)") {
                    workspace.adjustFontSize(sessionID: session.id, by: 1)
                }
            }

            if let root = project?.root {
                Text(NSString(string: root).abbreviatingWithTildeInPath)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.regularMaterial)
        .animation(Motion.state, value: session.zoomedPaneID)
    }

    private func barButton(_ icon: AppIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIconView(icon, size: 12)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func beginRename(_ session: TerminalSession) {
        draftName = session.name
        renaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename(_ session: TerminalSession) {
        workspace.renameSession(session.id, to: draftName)
        renaming = false
        focusCurrentPane(session)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(_ session: TerminalSession) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showingHelp.toggle()
            } label: {
                NucleoLabel("Shortcuts", icon: .info)
            }
            .help("Keyboard shortcuts")
            .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                ShortcutsHelpPopover()
            }

            Button {
                workspace.split(sessionID: session.id, axis: .horizontal)
            } label: {
                NucleoLabel("Split Right", icon: .splitRight)
            }
            .disabled(!workspace.canAddPane(to: session.id))
            .help("Open a new terminal to the right (⌘D)")

            Button {
                workspace.split(sessionID: session.id, axis: .vertical)
            } label: {
                NucleoLabel("Split Down", icon: .splitDown)
            }
            .disabled(!workspace.canAddPane(to: session.id))
            .help("Open a new terminal below (⇧⌘D)")

            Menu {
                Button("New Agent Terminal") {
                    workspace.split(sessionID: session.id, axis: .horizontal, kind: .agent)
                }
                Button("New Shell Terminal") {
                    workspace.split(sessionID: session.id, axis: .horizontal, kind: .shell)
                }
                Divider()
                Button("Rename Session…") { beginRename(session) }
                Button("Close Session", role: .destructive) {
                    workspace.removeSession(session.id)
                    workspace.pendingSelection = .project(session.projectID)
                }
            } label: {
                NucleoLabel("More", icon: .dots)
            }
            .help("More session actions")

            Button {
                workspace.toggleZoom(sessionID: session.id)
            } label: {
                NucleoLabel(session.zoomedPaneID == nil ? "Zoom Pane" : "Unzoom", icon: .fullscreen)
            }
            .disabled(session.panes.count < 2)
            .help("Show only the focused terminal (⇧⌘↩)")

            Button {
                workspace.toggleEnvPanel(projectID: session.projectID)
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
        }
    }
}

// MARK: - Pane

/// One terminal with its header. The header shows the process title (Claude
/// Code names its sessions) and the working directory, and reveals the pane
/// actions on hover so the chrome stays quiet while you work.
private struct PaneView: View {
    let session: TerminalSession
    let pane: TerminalPaneConfig
    @ObservedObject var runtime: TerminalPaneRuntime
    let isFocused: Bool
    let isZoomed: Bool
    let canSplit: Bool

    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var hovering = false
    @State private var confirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                StudioTerminalHost(runtime: runtime)
                if !runtime.isRunning {
                    exitedOverlay
                        .transition(.opacity)
                }
            }
        }
        .background(Color(nsColor: TerminalTheme.background))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.75) : Color(nsColor: TerminalTheme.border),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .animation(Motion.state, value: isFocused)
        .animation(Motion.paneSwap, value: runtime.isRunning)
        .animation(Motion.state, value: workspace.activity(for: pane.id))
        .onHover { hovering = $0 }
        .contextMenu { paneMenu }
        .confirmationDialog(
            "Start a new chat in this terminal?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                workspace.resetPane(sessionID: session.id, paneID: pane.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pane.agentSessionID == nil
                ? "The shell restarts from the project root."
                : "The current conversation ends and \(workspace.config.defaultAgent.shortName) starts fresh. The old one stays available through the agent's own resume.")
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            NucleoIconView(kindIcon, size: 11)
                .foregroundStyle(isFocused ? Color.accentColor : Color(nsColor: TerminalTheme.foreground).opacity(0.55))

            Text(runtime.title)
                .font(PortlyTypography.bodyMedium)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(isFocused ? 0.95 : 0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            if workspace.activity(for: pane.id) == .working {
                ProgressView()
                    .controlSize(.mini)
                    .colorScheme(.dark)
                    .transition(.opacity)
                    .accessibilityLabel("Working")
            }

            if let directory = runtime.currentDirectory, directory != runtime.projectRoot {
                Text(NSString(string: directory).abbreviatingWithTildeInPath)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
            }

            Spacer(minLength: 6)

            if !runtime.isRunning {
                Text("exited")
                    .font(PortlyTypography.label)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 2) {
                headerButton(.splitRight, help: "Split right") {
                    workspace.split(sessionID: session.id, paneID: pane.id, axis: .horizontal)
                }
                .disabled(!canSplit)
                headerButton(.splitDown, help: "Split down") {
                    workspace.split(sessionID: session.id, paneID: pane.id, axis: .vertical)
                }
                .disabled(!canSplit)
                headerButton(.fullscreen, help: isZoomed ? "Unzoom" : "Zoom this terminal") {
                    workspace.toggleZoom(sessionID: session.id, paneID: pane.id)
                }
                .disabled(session.panes.count < 2 && !isZoomed)
                headerButton(.restart, help: "Reset: new chat in this terminal") {
                    confirmingReset = true
                }
                headerButton(.xmark, help: "Close this terminal (⌘W)") {
                    workspace.closePane(sessionID: session.id, paneID: pane.id)
                }
            }
            .opacity(hovering || isFocused ? 1 : 0)
            .animation(Motion.hover, value: hovering)
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Color.white.opacity(isFocused ? 0.045 : 0.025))
        .contentShape(Rectangle())
        .onTapGesture { runtime.focus() }
    }

    private var kindIcon: String {
        if pane.kind == .agent {
            return workspace.config.defaultAgent.iconID
        }
        return AppIcon.terminal.rawValue
    }

    private func headerButton(_ icon: AppIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIconView(icon, size: 11)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var exitedOverlay: some View {
        VStack(spacing: 10) {
            NucleoIconView(.power, size: 26)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.5))
            Text(runtime.exitCode.map { "Shell exited with code \($0)" } ?? "Shell exited")
                .font(PortlyTypography.body)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.75))
            HStack(spacing: 8) {
                Button("New Shell") { runtime.restart() }
                    .buttonStyle(.borderedProminent)
                Button("Close") {
                    workspace.closePane(sessionID: session.id, paneID: pane.id)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(20)
        .background(Color(nsColor: TerminalTheme.background).opacity(0.86), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: TerminalTheme.border))
        }
    }

    @ViewBuilder
    private var paneMenu: some View {
        Button("Split Right") { workspace.split(sessionID: session.id, paneID: pane.id, axis: .horizontal) }
            .disabled(!canSplit)
        Button("Split Down") { workspace.split(sessionID: session.id, paneID: pane.id, axis: .vertical) }
            .disabled(!canSplit)
        Divider()
        Button(isZoomed ? "Unzoom" : "Zoom") { workspace.toggleZoom(sessionID: session.id, paneID: pane.id) }
        Button("Clear") { runtime.clear() }
        Button("Reset (new chat)…") { confirmingReset = true }
        if !runtime.isRunning {
            Button("New Shell") { runtime.restart() }
        }
        Divider()
        Button("Close Terminal") { workspace.closePane(sessionID: session.id, paneID: pane.id) }
    }
}

/// Hosts a pane's terminal view. The runtime owns the view; this only parents
/// it, so switching sessions never rebuilds a terminal.
struct StudioTerminalHost: NSViewRepresentable {
    let runtime: TerminalPaneRuntime
    var inset: CGFloat = 10

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.inset = inset
        container.embed(runtime.terminalView())
        return container
    }

    func updateNSView(_ nsView: Container, context: Context) {
        nsView.inset = inset
        nsView.embed(runtime.terminalView())
    }

    final class Container: NSView {
        var inset: CGFloat = 10
        private weak var current: NSView?
        private var edges: [NSLayoutConstraint] = []

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = TerminalTheme.background.cgColor
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }

        func embed(_ view: NSView) {
            guard current !== view else { return }
            current?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.wantsLayer = true
            view.layer?.backgroundColor = TerminalTheme.background.cgColor
            addSubview(view)
            NSLayoutConstraint.deactivate(edges)
            edges = [
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                view.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            ]
            NSLayoutConstraint.activate(edges)
            current = view
        }
    }
}
