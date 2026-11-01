import AppKit
import SwiftUI

/// The Things panel's type scale: a notch below the main sidebar, so it reads
/// as a companion rather than a second sidebar.
private enum ThingsType {
    static let heading = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let task = Font.system(size: 12, weight: .medium, design: .rounded)
    static let branch = Font.system(size: 11.5, weight: .regular, design: .rounded)
    static let section = Font.system(size: 9.5, weight: .semibold, design: .rounded)
    static let meta = Font.system(size: 9.5, weight: .regular, design: .monospaced)
}

/// The right-hand panel: the followed Things area, with the work handed to
/// agents hanging under each to-do. It floats over the window instead of
/// taking room from it, so opening it never resizes a terminal.
struct ThingsPanel: View {
    private static let radius: CGFloat = 12

    @ObservedObject private var center = ThingsCenter.shared
    @ObservedObject private var chrome = ThingsCenter.shared.chrome
    @Namespace private var flow
    @State private var adding = false
    @State private var draft = ""
    @State private var collapsed: Set<String> = []
    /// The width while the edge is dragged, kept here so a drag redraws the
    /// panel alone; the window learns the new width when the drag ends.
    @State private var dragWidth: CGFloat?
    @FocusState private var draftFocused: Bool

    private var width: CGFloat { dragWidth ?? chrome.width }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(.thickMaterial)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .overlay(alignment: .leading) {
            PanelResizeHandle(
                onDrag: { start, translation in dragWidth = ThingsChrome.clamped(start - translation) },
                onEnd: {
                    if let dragWidth { chrome.setWidth(dragWidth) }
                    dragWidth = nil
                },
                onReset: { withAnimation(Motion.panel) { chrome.setWidth(ThingsChrome.defaultWidth) } },
                currentWidth: { width }
            )
            .padding(.vertical, Self.radius)
            .offset(x: -PanelResizeHandle.hitWidth / 2)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            NucleoIconView(.checkList, size: 12)
                .foregroundStyle(.secondary)
            Text(center.area?.title ?? "Things")
                .font(ThingsType.heading)
                .lineLimit(1)
            if !center.tasks.isEmpty {
                Text("\(center.tasks.count - center.completing.count)")
                    .font(ThingsType.meta)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            // Something is being sorted: the panel says so before it knows where it goes.
            if !center.pending.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .transition(.blurScale)
                    .accessibilityLabel("Sorting a prompt")
            }
            Spacer(minLength: 4)
            PanelIconButton(icon: .plus, help: "New to-do in \(center.area?.title ?? "Things")") {
                withAnimation(Motion.state) { adding.toggle() }
                if adding { draftFocused = true }
            }
            .disabled(center.area == nil)
            settingsMenu
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 36)
        .animation(Motion.state, value: center.pending.isEmpty)
    }

    private var settingsMenu: some View {
        Menu {
            if center.areas.count > 1 {
                Picker("Area", selection: Binding(
                    get: { center.area?.id ?? "" },
                    set: { center.selectArea($0) }
                )) {
                    ForEach(center.areas) { area in Text(area.title).tag(area.id) }
                }
                Divider()
            }
            Toggle("Sort my prompts with Sonnet", isOn: Binding(
                get: { center.autoSort },
                set: { center.setAutoSort($0) }
            ))
            Divider()
            Button("Open Things") { center.openThings() }
            Button("Hide Panel") { center.setVisible(false) }
        } label: {
            NucleoIconView(.dots, size: 13)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .help("Panel settings")
        .accessibilityLabel("Panel settings")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch center.availability {
        case .unknown:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            emptyState(icon: .checkList, title: "Things 3 is not here", detail: "Install Things 3 and open it once; its to-dos show up here.")
        case .unreadable(let message):
            emptyState(icon: .warning, title: "Things cannot be read", detail: message)
        case .ready:
            if center.area == nil {
                emptyState(icon: .folder, title: "No area in Things", detail: "Create an area in Things, such as “Projets”, and put the to-dos for Portly in it.")
            } else {
                board
            }
        }
    }

    private var board: some View {
        let rows = center.rows
        let started = rows.filter { !$0.branches.isEmpty }
        let waiting = rows.filter { $0.branches.isEmpty }
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if adding { addField.transition(.opacity.combined(with: .offset(y: -4))) }
                if !center.canEditThings { urlsNotice }
                if !center.pending.isEmpty {
                    sectionLabel("Sorting")
                    ForEach(center.pending) { job in
                        PendingRow(job: job)
                            .matchedGeometryEffect(id: job.id, in: flow)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: -6)),
                                removal: .blurFade
                            ))
                    }
                }
                if !started.isEmpty {
                    sectionLabel("In progress")
                    ForEach(started) { row in taskBlock(row) }
                }
                if !waiting.isEmpty {
                    if !started.isEmpty || !center.pending.isEmpty { sectionLabel("To do") }
                    ForEach(waiting) { row in taskBlock(row) }
                }
                if rows.isEmpty, center.pending.isEmpty {
                    Text("Nothing left in \(center.area?.title ?? "this area").")
                        .font(ThingsType.branch)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }

    private func taskBlock(_ row: ThingsBoard.Row) -> some View {
        let isCollapsed = collapsed.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            TaskRow(row: row, isCollapsed: isCollapsed) {
                guard !row.branches.isEmpty else { return }
                withAnimation(Motion.state) {
                    if isCollapsed { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                }
            }
            if !isCollapsed {
                ForEach(Array(row.branches.enumerated()), id: \.element.id) { index, branch in
                    BranchRow(branch: branch, isLast: index == row.branches.count - 1)
                        .matchedGeometryEffect(id: branch.id, in: flow)
                        .transition(.blurFade)
                }
            }
        }
        .padding(.bottom, row.branches.isEmpty || isCollapsed ? 0 : 4)
        // A to-do getting its first branch travels up to "In progress"
        // rather than vanishing from one section and appearing in the other.
        .matchedGeometryEffect(id: "task-\(row.id)", in: flow)
        .transition(.opacity)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(ThingsType.section)
            .foregroundStyle(.tertiary)
            .kerning(0.5)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private var addField: some View {
        HStack(spacing: 8) {
            NucleoIconView(.circlePlus, size: 13)
                .foregroundStyle(.secondary)
            TextField("New to-do", text: $draft)
                .textFieldStyle(.plain)
                .font(ThingsType.task)
                .focused($draftFocused)
                .onSubmit {
                    center.addTask(title: draft)
                    draft = ""
                }
                .onExitCommand {
                    draft = ""
                    withAnimation(Motion.state) { adding = false }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.bottom, 4)
    }

    private var urlsNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To tick and add to-dos from here, turn on Things URLs: Things → Settings → General.")
                .font(ThingsType.branch)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Things") { center.openThings() }
                .controlSize(.small)
                .pointingHandCursor()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.08)))
        .padding(.bottom, 4)
    }

    private func emptyState(icon: AppIcon, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            NucleoIconView(icon, size: 20)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(ThingsType.task)
            Text(detail)
                .font(ThingsType.branch)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let notice = center.notice {
                NucleoIconView(.warning, size: 10)
                    .foregroundStyle(.orange)
                Text(notice)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .transition(.opacity)
            } else {
                Text(summary)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .font(ThingsType.meta)
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
        .animation(Motion.state, value: summary)
    }

    private var summary: String {
        let working = center.branches.filter { $0.state == .working }.count
        let review = center.branches.filter { $0.state == .review || $0.state == .waiting }.count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if review > 0 { parts.append("\(review) to review") }
        if parts.isEmpty { return center.autoSort ? "Sorting prompts with Sonnet" : "Sorting is off" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Rows

/// A prompt the sorting agent is reading. It either fades away or travels
/// to its to-do and becomes a branch.
private struct PendingRow: View {
    let job: TriageJob

    @State private var breathing = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(job.excerpt)”")
                    .font(ThingsType.branch)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(StudioWorkspace.shared.terminalName(paneID: job.paneID) ?? "Terminal")
                    .font(ThingsType.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(breathing ? 0.09 : 0.04))
        }
        .onAppear {
            withAnimation(Motion.pulse) { breathing = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sorting: \(job.excerpt)")
    }
}

/// One Things to-do: tick it to finish it in Things, click it to fold its branches.
private struct TaskRow: View {
    let row: ThingsBoard.Row
    let isCollapsed: Bool
    let onToggle: () -> Void

    @ObservedObject private var center = ThingsCenter.shared
    @State private var hovering = false
    @State private var hoveringCheck = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                center.complete(row.task)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(hoveringCheck ? 0.9 : 0.5), lineWidth: 1.2)
                    if hoveringCheck {
                        NucleoIconView(.check, size: 8)
                            .foregroundStyle(.secondary)
                            .transition(.blurScale)
                    }
                }
                .frame(width: 14, height: 14)
                // A 20 pt target around a 14 pt circle, centred on the branch rail.
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .padding(.vertical, -2)
            .onHover { inside in withAnimation(Motion.hover) { hoveringCheck = inside } }
            .pointingHandCursor()
            .help(center.canEditThings ? "Mark as done in Things" : ThingsCenter.urlsOffNotice)
            .accessibilityLabel("Mark “\(row.task.title)” as done")

            VStack(alignment: .leading, spacing: 2) {
                Text(row.task.title)
                    .font(ThingsType.task)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let meta {
                    Text(meta)
                        .font(ThingsType.meta)
                        .foregroundStyle(isOverdue ? Color.orange : Color.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            indicators
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .contextMenu {
            Button("Open in Things") { center.openInThings(row.task) }
            Button("Link the Terminal on Screen") { center.linkTerminalOnScreen(to: row.task) }
            Divider()
            Button("Mark as Done in Things") { center.complete(row.task) }
        }
        .animation(Motion.state, value: row.workingCount)
        .animation(Motion.state, value: row.needsYouCount)
    }

    /// The summary stays visible when the branches are folded away.
    @ViewBuilder
    private var indicators: some View {
        HStack(spacing: 5) {
            if isCollapsed, row.workingCount > 0 {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .transition(.blurScale)
            }
            if isCollapsed, row.needsYouCount > 0 {
                Text("\(row.needsYouCount)")
                    .font(ThingsType.meta.weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(Color.orange))
                    .transition(.blurScale)
                    .accessibilityLabel("\(row.needsYouCount) to review")
            }
            if !row.branches.isEmpty {
                NucleoIconView(.chevronDown, size: 9)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 2)
    }

    private var meta: String? {
        var parts: [String] = []
        if let project = row.task.projectTitle { parts.append(project) }
        if let deadline = deadlineDate { parts.append("⚑ " + deadline.formatted(.dateTime.day().month(.abbreviated))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var deadlineDate: Date? {
        row.task.deadline.flatMap { Calendar.current.date(from: $0) }
    }

    private var isOverdue: Bool {
        guard let deadlineDate else { return false }
        return deadlineDate <= Calendar.current.startOfDay(for: Date())
    }
}

/// One piece of a to-do, running in one terminal. Click it to go to that
/// terminal; tick it once you have reviewed the work.
private struct BranchRow: View {
    let branch: ThingsBranch
    let isLast: Bool

    @ObservedObject private var center = ThingsCenter.shared
    @State private var hovering = false

    private var isDone: Bool { branch.state == .done }

    var body: some View {
        HStack(spacing: 0) {
            TreeRail(isLast: isLast)
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(branch.label)
                        .font(ThingsType.branch)
                        .strikethrough(isDone, color: .secondary)
                        .foregroundStyle(isDone ? Color.secondary.opacity(0.7) : Color.primary)
                        .lineLimit(1)
                    Text(center.terminalName(for: branch))
                        .font(ThingsType.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovering, !isDone {
                    PanelIconButton(icon: .check, size: 10, help: "Reviewed") { center.markReviewed(branch) }
                        .transition(.blurScale)
                }
                if hovering || isDone {
                    PanelIconButton(icon: .xmark, size: 9, help: "Remove") { center.remove(branch) }
                        .transition(.blurScale)
                }
                BranchStatus(state: branch.state)
            }
            .padding(.trailing, 4)
            .padding(.vertical, 4)
        }
        .padding(.leading, 8)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { center.reveal(branch) }
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .pointingHandCursor()
        .help(help)
        .contextMenu {
            Button("Open the Terminal") { center.reveal(branch) }
            if isDone {
                Button("Mark as Not Reviewed") { center.markNotReviewed(branch) }
            } else {
                Button("Mark as Reviewed") { center.markReviewed(branch) }
            }
            Menu("Move to") {
                ForEach(center.tasks.filter { $0.id != branch.taskID }) { task in
                    Button(task.title) { center.move(branch, to: task) }
                }
            }
            Divider()
            Button("Remove") { center.remove(branch) }
        }
        .animation(Motion.state, value: branch.state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(branch.label), \(stateName)")
    }

    private var stateName: String {
        switch branch.state {
        case .working: return "agent working"
        case .waiting: return "agent waiting for you"
        case .review: return "to review"
        case .done: return "reviewed"
        }
    }

    private var help: String {
        switch branch.state {
        case .working: return "The agent is working. Click to open its terminal."
        case .waiting: return "The agent is waiting for you. Click to open its terminal."
        case .review: return "Finished: review it, then tick it."
        case .done: return "Reviewed. Remove it with ×."
        }
    }
}

/// Spinner while the agent works, a pulsing ring while it waits for you, an
/// orange dot once it is done and yours to review.
private struct BranchStatus: View {
    let state: ThingsBranch.State

    @State private var pulse = false

    var body: some View {
        ZStack {
            switch state {
            case .working:
                ProgressView()
                    .controlSize(.mini)
                    .transition(.blurScale)
            case .waiting:
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.15 : 0.9)
                    .onAppear { withAnimation(Motion.pulse) { pulse = true } }
                    .transition(.blurScale)
            case .review:
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.orange.opacity(0.55), radius: 3)
                    .transition(.blurScale)
            case .done:
                EmptyView()
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// The branch's connector to its to-do, lined up under the tick circle.
private struct TreeRail: View {
    let isLast: Bool

    /// The tick circle's centre: 8 pt of row padding plus half its 20 pt target.
    private let railX: CGFloat = 10
    private let tick: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let midY = proxy.size.height / 2
                path.move(to: CGPoint(x: railX, y: -4))
                path.addLine(to: CGPoint(x: railX, y: isLast ? midY : proxy.size.height + 4))
                path.move(to: CGPoint(x: railX, y: midY))
                path.addLine(to: CGPoint(x: railX + tick, y: midY))
            }
            .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .frame(width: railX + tick + 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Controls

private struct PanelIconButton: View {
    let icon: AppIcon
    var size: CGFloat = 12
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            NucleoIconView(icon, size: size)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .pointingHandCursor()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A press reads as a press: 96 %, never smaller.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}

/// The toolbar's way into the panel, with an orange dot when work waits for
/// your review while the panel is closed.
struct ThingsToolbarButton: View {
    @ObservedObject private var chrome = ThingsCenter.shared.chrome

    var body: some View {
        Button {
            ThingsCenter.shared.toggleVisible()
        } label: {
            NucleoIconView(chrome.isVisible ? .sidebarRightHide : .sidebarRight, size: 14)
                .overlay(alignment: .topTrailing) {
                    if !chrome.isVisible, chrome.needsYouCount > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                            .transition(.blurScale)
                    }
                }
                .animation(Motion.state, value: chrome.needsYouCount)
        }
        .help("Things to-dos (⌥⌘T)")
        .accessibilityLabel(chrome.isVisible ? "Hide Things to-dos" : "Show Things to-dos")
        .accessibilityValue(chrome.needsYouCount > 0 ? "\(chrome.needsYouCount) to review" : "")
    }
}

// MARK: - Motion helpers

private struct BlurScaleModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.25 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 4 : 0)
    }
}

private struct BlurFadeModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 3 : 0)
            .offset(y: active ? -3 : 0)
    }
}

extension AnyTransition {
    /// Icons swapping in place: scale from 25 %, fade and unblur.
    static var blurScale: AnyTransition {
        .modifier(active: BlurScaleModifier(active: true), identity: BlurScaleModifier(active: false))
    }

    /// A row leaving: a soft fade and blur with a small lift, softer than its entrance.
    static var blurFade: AnyTransition {
        .modifier(active: BlurFadeModifier(active: true), identity: BlurFadeModifier(active: false))
    }
}

/// Pushes the pointing hand while hovered, and pops it if the view goes away
/// under the pointer, which would otherwise leave the hand stuck.
/// The panel's left edge: drag it to widen the panel, double-click it to
/// bring the panel back to its usual width.
private struct PanelResizeHandle: View {
    static let hitWidth: CGFloat = 10

    /// The width when the drag began, and how far the pointer has moved since.
    let onDrag: (_ startWidth: CGFloat, _ translation: CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    let currentWidth: () -> CGFloat

    @State private var hovering = false
    @State private var startWidth: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        let dragging = startWidth != nil
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.primary.opacity(dragging ? 0.45 : 0.25))
                .frame(width: 3, height: 36)
                .opacity(hovering || dragging ? 1 : 0)
        }
        .frame(width: Self.hitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(Motion.hover, value: hovering || dragging)
        .onHover { inside in
            hovering = inside
            updateCursor()
        }
        .gesture(
            // Global space: the edge moves with the drag, the pointer's path does not.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? currentWidth()
                    if startWidth == nil {
                        startWidth = start
                        updateCursor()
                    }
                    onDrag(start, value.translation.width)
                }
                .onEnded { _ in
                    startWidth = nil
                    onEnd()
                    updateCursor()
                }
        )
        .onTapGesture(count: 2, perform: onReset)
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .accessibilityLabel("Resize the Things panel")
    }

    /// One push while the pointer is on the edge or dragging it, one pop after.
    private func updateCursor() {
        let wanted = hovering || startWidth != nil
        if wanted, !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !wanted, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    /// The pointing hand over something clickable.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}
