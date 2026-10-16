import AppKit
import PortlyCore
import SwiftUI
import UniformTypeIdentifiers

/// The free terminal: a strip of tabs along the top, iTerm-style, each a
/// login shell that belongs to no project and starts in your home folder.
/// The place for whatever is not a project's business: a quick look at a
/// folder, a `brew upgrade`, a Claude Code chat about nothing in particular.
///
/// Like `SessionView`, the outer view observes nothing so the window toolbar
/// is not rebuilt on every title or activity change.
struct TerminalWorkspaceView: View {
    var body: some View {
        TerminalWorkspaceContent()
            .toolbar { TerminalWorkspaceToolbar() }
    }
}

private struct TerminalWorkspaceContent: View {
    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var draggingTabID: String?

    var body: some View {
        VStack(spacing: 0) {
            TerminalTabStrip(dragging: $draggingTabID)
            Divider()
            if let tab = workspace.activeTerminalTab {
                TerminalTabContent(tab: tab, runtime: workspace.terminalTabRuntime(for: tab))
                    .id(tab.id)
                    .padding(8)
            } else {
                emptyState
            }
        }
        .navigationTitle("Terminal")
        .navigationSubtitle(subtitle)
        .onAppear {
            workspace.terminalWorkspaceVisible = true
            if workspace.terminalTabs.isEmpty {
                workspace.createTerminalTab()
            }
            workspace.warmTerminalTabs()
            focusActiveTab()
        }
        .onDisappear {
            workspace.terminalWorkspaceVisible = false
        }
        .onChange(of: workspace.config.activeTerminalTabID) { focusActiveTab() }
    }

    private var subtitle: String {
        let count = workspace.terminalTabs.count
        return count == 1 ? "1 tab" : "\(count) tabs"
    }

    private func focusActiveTab() {
        guard let tab = workspace.activeTerminalTab else { return }
        DispatchQueue.main.async {
            workspace.existingTerminalTabRuntime(tab.id)?.focus()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            NucleoIconView(.terminalSquare, size: 30)
                .foregroundStyle(.tertiary)
            Text("No terminal open")
                .font(PortlyTypography.bodyMedium)
            Text("A tab is a login shell starting in your home folder.")
                .font(PortlyTypography.metadata)
                .foregroundStyle(.secondary)
            Button("New Tab") { workspace.createTerminalTab() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toolbar

private struct TerminalWorkspaceToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup {
            TerminalShortcutsButton()
            Button {
                StudioWorkspace.shared.createTerminalTab()
            } label: {
                NucleoLabel("New Tab", icon: .plus)
            }
            .help("Open a new tab at your home folder (⌘T)")
            TerminalTextSizeControl()
            Button {
                let workspace = StudioWorkspace.shared
                guard let tab = workspace.activeTerminalTab else { return }
                workspace.existingTerminalTabRuntime(tab.id)?.clear()
            } label: {
                NucleoLabel("Clear", icon: .broom)
            }
            .help("Clear the current tab (⌘K)")
        }
    }
}

private struct TerminalShortcutsButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            NucleoLabel("Shortcuts", icon: .info)
        }
        .help("Keyboard shortcuts")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ShortcutsHelpPopover()
        }
    }
}

private struct TerminalTextSizeControl: View {
    @ObservedObject private var workspace = StudioWorkspace.shared

    var body: some View {
        HStack(spacing: 2) {
            Button {
                workspace.adjustTerminalFontSize(by: -1)
            } label: {
                NucleoLabel("Smaller Text", icon: .textSmaller)
            }
            .help("Smaller text (⌘−)")
            Text("\(Int(workspace.terminalFontSize))")
                .font(PortlyTypography.metric)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 22)
            Button {
                workspace.adjustTerminalFontSize(by: 1)
            } label: {
                NucleoLabel("Bigger Text", icon: .textBigger)
            }
            .help("Bigger text (⌘+)")
        }
    }
}

// MARK: - Tab strip

/// The tabs, equal in width and shrinking together as more open, with the
/// `+` at the end. Past a dozen the strip scrolls rather than crush them.
private struct TerminalTabStrip: View {
    @Binding var dragging: String?

    @ObservedObject private var workspace = StudioWorkspace.shared

    private static let height: CGFloat = 40
    private static let spacing: CGFloat = 4
    private static let minimumWidth: CGFloat = 112
    private static let maximumWidth: CGFloat = 224
    private static let newTabWidth: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            let tabs = workspace.terminalTabs
            let available = proxy.size.width - Self.newTabWidth - Self.spacing * CGFloat(tabs.count) - 16
            let fitted = tabs.isEmpty ? Self.maximumWidth : available / CGFloat(tabs.count)
            let width = min(max(fitted, Self.minimumWidth), Self.maximumWidth)
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            TerminalTabButton(
                                tab: tab,
                                index: index,
                                isActive: workspace.activeTerminalTab?.id == tab.id,
                                width: width,
                                height: Self.height
                            )
                            .id(tab.id)
                            .onDrag {
                                dragging = tab.id
                                return TabReorderDropDelegate.itemProvider(for: tab.id)
                            }
                            .onDrop(
                                of: [TabReorderDropDelegate.dragType],
                                delegate: TabReorderDropDelegate(targetID: tab.id, dragging: $dragging) { moved, target in
                                    workspace.moveTerminalTab(moved, onto: target)
                                }
                            )
                        }
                        newTabButton
                    }
                    .padding(.horizontal, 8)
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                    .animation(Motion.reorder, value: tabs.map(\.id))
                }
                .onChange(of: workspace.config.activeTerminalTabID) {
                    guard let id = workspace.config.activeTerminalTabID else { return }
                    withAnimation(Motion.state) { scroller.scrollTo(id) }
                }
            }
        }
        .frame(height: Self.height + 12)
        .background(.regularMaterial)
        .contextMenu {
            Button("New Tab") { workspace.createTerminalTab() }
        }
    }

    private var newTabButton: some View {
        Button {
            workspace.createTerminalTab()
        } label: {
            NucleoIconView(.plus, size: 11)
                .foregroundStyle(.secondary)
                .frame(width: Self.newTabWidth, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New tab (⌘T)")
        .accessibilityLabel("New tab")
    }
}

/// One tab: the cross on its left, the folder it is in, and what the shell
/// is up to. Double-click the name to rename it.
private struct TerminalTabButton: View {
    let tab: TerminalTab
    let index: Int
    let isActive: Bool
    let width: CGFloat
    let height: CGFloat

    @ObservedObject private var workspace = StudioWorkspace.shared
    @ObservedObject private var runtime: TerminalPaneRuntime
    @State private var hovering = false
    @State private var hoveringClose = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    init(tab: TerminalTab, index: Int, isActive: Bool, width: CGFloat, height: CGFloat) {
        self.tab = tab
        self.index = index
        self.isActive = isActive
        self.width = width
        self.height = height
        _runtime = ObservedObject(wrappedValue: StudioWorkspace.shared.terminalTabRuntime(for: tab))
    }

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private var directory: String { runtime.currentDirectory ?? tab.lastDirectory ?? runtime.projectRoot }

    /// The folder's name, "Home" for the home folder itself.
    private var automaticTitle: String {
        directory == home ? "Home" : (directory as NSString).lastPathComponent
    }

    private var title: String { tab.name ?? automaticTitle }

    private var hasExited: Bool { runtime.hasStarted && !runtime.isRunning }

    /// What the shell says it is doing when it says something, else where it is.
    private var subtitle: String {
        if hasExited { return "exited" }
        let path = NSString(string: directory).abbreviatingWithTildeInPath
        let reported = runtime.title
        if reported != "Terminal", !reported.isEmpty, reported != path, reported != directory {
            return reported
        }
        return path
    }

    private var activity: PaneActivity { workspace.activity(for: tab.id) }

    var body: some View {
        HStack(spacing: 7) {
            closeButton
            NucleoIconView(.terminal, size: 11)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    TextField("Tab name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(PortlyTypography.bodyMedium)
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { editing = false }
                        .onChange(of: nameFocused) { if !nameFocused, editing { commitRename() } }
                } else {
                    Text(title)
                        .font(PortlyTypography.bodyMedium)
                        .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(subtitle)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(hasExited ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 2)
            statusIndicator
            if index < 9, width >= 150 {
                Text("⌘\(index + 1)")
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .frame(width: width, height: height)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.1 : hovering ? 0.05 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(isActive ? 0.08 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { workspace.selectTerminalTab(tab.id) }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.state, value: isActive)
        .animation(Motion.state, value: activity)
        .contextMenu { menu }
        .help(NSString(string: directory).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) tab")
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityAction(named: "Close tab") { workspace.closeTerminalTab(tab.id) }
        .accessibilityAction(named: "Rename tab") { beginRename() }
    }

    /// Always there on the active tab, on hover elsewhere; the space it
    /// takes never changes so the title does not shift.
    private var closeButton: some View {
        Button {
            workspace.closeTerminalTab(tab.id)
        } label: {
            NucleoIconView(.xmark, size: 9)
                .foregroundStyle(hoveringClose ? Color.primary : Color.secondary)
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hoveringClose ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isActive || hovering ? 1 : 0)
        .onHover { hoveringClose = $0 }
        .animation(Motion.hover, value: hoveringClose)
        .help("Close tab (⌘W)")
        .accessibilityLabel("Close \(title)")
    }

    @ViewBuilder
    private var statusIndicator: some View {
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
            Circle()
                .fill(hasExited ? Color.orange : runtime.isRunning ? ServerState.running.color : Color.secondary)
                .frame(width: 6, height: 6)
                .opacity(runtime.isRunning || hasExited ? 0.9 : 0.35)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…", action: beginRename)
        if tab.name != nil {
            Button("Use the Folder Name") { workspace.renameTerminalTab(tab.id, to: nil) }
        }
        Divider()
        Button("New Tab") { workspace.createTerminalTab() }
        Button("New Tab Here") { workspace.createTerminalTab(directory: directory) }
        Divider()
        let tabs = workspace.terminalTabs
        Button("Move Left") { workspace.moveTerminalTab(tab.id, by: -1) }
            .disabled(index == 0)
        Button("Move Right") { workspace.moveTerminalTab(tab.id, by: 1) }
            .disabled(index == tabs.count - 1)
        Divider()
        if hasExited {
            Button("New Shell") { runtime.restart() }
        }
        Button("Reveal Folder in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
        }
        Divider()
        Button("Close Tab") { workspace.closeTerminalTab(tab.id) }
        Button("Close Other Tabs") { workspace.closeOtherTerminalTabs(tab.id) }
            .disabled(tabs.count < 2)
    }

    private func beginRename() {
        draft = tab.name ?? automaticTitle
        editing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard editing else { return }
        editing = false
        workspace.renameTerminalTab(tab.id, to: draft == automaticTitle ? nil : draft)
        workspace.selectTerminalTab(tab.id)
    }
}

/// Lets a dragged tab take the place of the one it passes over, the way the
/// sidebar's projects do. The type is Portly's own, so text or files dragged
/// in from elsewhere never move a tab.
private struct TabReorderDropDelegate: DropDelegate {
    static let dragType = UTType(exportedAs: "dev.portly.terminal-tab")

    let targetID: String
    @Binding var dragging: String?
    let onMove: (_ dragged: String, _ target: String) -> Void

    static func itemProvider(for tabID: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) { completion in
            completion(Data(tabID.utf8), nil)
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

// MARK: - Tab content

/// The active tab's shell in the same surface a session pane uses, with the
/// "shell exited" card when it is gone.
private struct TerminalTabContent: View {
    let tab: TerminalTab
    @ObservedObject var runtime: TerminalPaneRuntime

    @ObservedObject private var workspace = StudioWorkspace.shared

    var body: some View {
        ZStack {
            StudioTerminalHost(runtime: runtime)
            if !runtime.isRunning {
                exitedOverlay
                    .transition(.opacity)
            }
        }
        .background(Color(nsColor: TerminalTheme.background))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: TerminalTheme.border))
        }
        .animation(Motion.paneSwap, value: runtime.isRunning)
        .onAppear {
            DispatchQueue.main.async { runtime.focus() }
        }
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
                Button("Close Tab") { workspace.closeTerminalTab(tab.id) }
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
}
