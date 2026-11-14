import AppKit
import PortlyCore
import SwiftUI
import UniformTypeIdentifiers

/// A project window's sessions as a thin row of tabs: one line each, the
/// agent's mark, the name, and a spinner or a dot when there is news. Lower
/// and quieter than the free terminal's strip, so the terminals keep the
/// room. A new session opens at the right end; tabs drag to reorder.
struct SessionTabStrip: View {
    @ObservedObject var model: ProjectWindowModel

    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var dragging: String?

    static let height: CGFloat = 30
    private static let edgePadding: CGFloat = 6
    private static let minimumWidth: CGFloat = 96
    private static let maximumWidth: CGFloat = 196
    private static let newTabWidth: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let sessions = workspace.sessions(for: model.projectID)
            let activeID = model.currentSession(in: sessions)?.id
            let available = proxy.size.width - Self.newTabWidth - Self.edgePadding * 2
            let fitted = sessions.isEmpty ? Self.maximumWidth : available / CGFloat(sessions.count)
            let width = min(max(fitted, Self.minimumWidth), Self.maximumWidth)
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            let next = index + 1 < sessions.count ? sessions[index + 1].id : nil
                            SessionTabButton(
                                session: session,
                                index: index,
                                count: sessions.count,
                                isActive: activeID == session.id,
                                showsSeparator: next != nil && next != activeID && activeID != session.id,
                                width: width,
                                model: model
                            )
                            .id(session.id)
                            .onDrag {
                                dragging = session.id
                                return SessionTabDropDelegate.itemProvider(for: session.id)
                            }
                            .onDrop(
                                of: [SessionTabDropDelegate.dragType],
                                delegate: SessionTabDropDelegate(targetID: session.id, dragging: $dragging) { moved, target in
                                    workspace.moveSession(moved, onto: target)
                                }
                            )
                        }
                        newSessionButton
                    }
                    .padding(.horizontal, Self.edgePadding)
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                    .animation(Motion.tabs, value: sessions.map(\.id))
                }
                .onChange(of: model.sessionID) {
                    guard let id = model.sessionID else { return }
                    withAnimation(Motion.tabs) { scroller.scrollTo(id) }
                }
            }
        }
        .frame(height: Self.height)
        .background(.bar)
        .contextMenu {
            Button("New Session") { model.newSession() }
        }
    }

    private var newSessionButton: some View {
        Button {
            model.newSession()
        } label: {
            NucleoIconView(.plus, size: 10)
                .foregroundStyle(.secondary)
                .frame(width: Self.newTabWidth, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New session with \(workspace.config.defaultAgent.shortName) (⌘N)")
        .accessibilityLabel("New session")
    }
}

/// One session tab. A click shows it on the spot; a double-click renames it;
/// the cross appears on hover at the right end, where the spinner or the dot
/// sits otherwise.
private struct SessionTabButton: View {
    let session: TerminalSession
    let index: Int
    let count: Int
    let isActive: Bool
    let showsSeparator: Bool
    let width: CGFloat
    @ObservedObject var model: ProjectWindowModel

    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var hovering = false
    @State private var hoveringClose = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    /// Rounded at the top only: the active tab runs into the terminals.
    private static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 6, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 6,
        style: .continuous
    )

    private var activity: PaneActivity { workspace.activity(for: session) }

    private var ink: Color {
        isActive ? Color(nsColor: TerminalTheme.foreground) : Color.primary.opacity(0.72)
    }

    private var dimInk: Color {
        isActive ? Color(nsColor: TerminalTheme.foreground).opacity(0.5) : Color.secondary
    }

    private var iconID: String {
        session.panes.first?.kind == .agent ? workspace.config.defaultAgent.iconID : AppIcon.terminal.rawValue
    }

    var body: some View {
        HStack(spacing: 6) {
            NucleoIconView(iconID, size: 10)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            if editing {
                TextField("Session name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(ink)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editing = false }
                    .onChange(of: nameFocused) { if !nameFocused, editing { commitRename() } }
            } else {
                Text(session.name)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular, design: .rounded))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 2)
            if session.panes.count > 1 {
                Text("\(session.panes.count)")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(dimInk)
                    .monospacedDigit()
                    .help("\(session.panes.count) terminals")
            }
            trailingSlot
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(width: width, height: SessionTabStrip.height)
        .background {
            Self.shape.fill(
                isActive ? Color(nsColor: TerminalTheme.background) : Color.primary.opacity(hovering ? 0.05 : 0)
            )
        }
        .overlay(alignment: .trailing) {
            if showsSeparator {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1, height: 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: handleClick)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.state, value: activity)
        .contextMenu { menu }
        .help(index < 9 ? "\(session.name) (⌘\(index + 1))" : session.name)
        .onChange(of: workspace.renameRequest) {
            guard workspace.renameRequest == session.id else { return }
            workspace.renameRequest = nil
            beginRename()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.name) session")
        .accessibilityValue(activity == .working ? "Working" : activity == .finished ? "Finished" : "")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityAction { model.selectSession(session.id) }
        .accessibilityAction(named: "Close session") { model.closeSession(session.id) }
        .accessibilityAction(named: "Rename session") { beginRename() }
    }

    /// The first click selects at once; the second click of a double-click is
    /// read off the event, so single clicks are never held back.
    private func handleClick() {
        guard !editing else { return }
        model.selectSession(session.id)
        if NSApp.currentEvent?.clickCount == 2 {
            beginRename()
        }
    }

    /// One fixed square at the right end: the activity at rest, the cross
    /// under the pointer. Nothing shifts, and a stray click on the active
    /// tab closes nothing.
    private var trailingSlot: some View {
        ZStack {
            statusIndicator
                .opacity(hovering ? 0 : 1)
            closeButton
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .frame(width: 16, height: 16)
    }

    private var closeButton: some View {
        Button {
            model.closeSession(session.id)
        } label: {
            NucleoIconView(.xmark, size: 8)
                .foregroundStyle(hoveringClose ? ink : dimInk)
                .frame(width: 16, height: 16)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hoveringClose ? ink.opacity(0.14) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringClose = $0 }
        .animation(Motion.hover, value: hoveringClose)
        .help("Close session")
        .accessibilityLabel("Close \(session.name)")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch activity {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.8)
                .frame(width: 10, height: 10)
                .transition(.opacity)
                .accessibilityHidden(true)
        case .finished:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .shadow(color: Color.accentColor.opacity(0.5), radius: 3)
                .transition(.opacity.combined(with: .scale(scale: 0.4)))
                .accessibilityHidden(true)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…", action: beginRename)
        Divider()
        Button("Split Left") { split(axis: .horizontal, before: true) }
        Button("Split Right") { split(axis: .horizontal) }
        Button("Split Down") { split(axis: .vertical) }
        Divider()
        Button("New Session") { model.newSession() }
        Button("Move Left") { workspace.moveSession(session.id, by: -1) }
            .disabled(index == 0)
        Button("Move Right") { workspace.moveSession(session.id, by: 1) }
            .disabled(index == count - 1)
        Divider()
        Button("Close Session") { model.closeSession(session.id) }
    }

    private func split(axis: SplitAxis, before: Bool = false) {
        model.selectSession(session.id)
        workspace.split(sessionID: session.id, axis: axis, before: before)
    }

    private func beginRename() {
        draft = session.name
        editing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard editing else { return }
        editing = false
        workspace.renameSession(session.id, to: draft)
        model.selectSession(session.id)
        model.updateTitle()
    }
}

/// A dragged tab takes the place of the one it passes over. The type is
/// Portly's own, so files or text dragged in from elsewhere never move one.
private struct SessionTabDropDelegate: DropDelegate {
    static let dragType = UTType(exportedAs: "dev.portly.session-tab")

    let targetID: String
    @Binding var dragging: String?
    let onMove: (_ dragged: String, _ target: String) -> Void

    static func itemProvider(for sessionID: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) { completion in
            completion(Data(sessionID.utf8), nil)
            return nil
        }
        return provider
    }

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil && info.hasItemsConforming(to: [Self.dragType])
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != targetID else { return }
        withAnimation(Motion.reorder) { onMove(dragging, targetID) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
