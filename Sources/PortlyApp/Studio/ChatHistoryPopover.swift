import PortlyCore
import SwiftUI

/// Every Claude conversation the project has had, newest first, under the
/// Chats button of a session's toolbar. A launch no longer brings old chats
/// back on its own; this is where you go for one. Picking it resumes it in
/// the focused terminal (see `StudioWorkspace.resumeChat`).
struct ChatHistoryPopover: View {
    let sessionID: String

    @ObservedObject private var workspace = StudioWorkspace.shared
    /// Nil while the transcripts are being read.
    @State private var chats: [ClaudeChat]?
    /// Conversations some Claude Code process runs right now.
    @State private var running: Set<String> = []
    @State private var query = ""
    @State private var highlightedID: String?
    @FocusState private var searchFocused: Bool

    private static let width: CGFloat = 400
    private static let listHeight: CGFloat = 400

    private var session: TerminalSession? { workspace.session(sessionID) }
    private var project: Project? { session.flatMap { workspace.project(for: $0) } }

    private var visibleChats: [ClaudeChat] {
        ChatHistory.matching(chats ?? [], query: query)
    }

    /// The rows a click or ↩ can act on, in the order they are drawn.
    private var selectableChats: [ClaudeChat] {
        ChatHistory.grouped(visibleChats).flatMap(\.chats).filter { place(of: $0) != .elsewhere }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: Self.width)
        .task { await load() }
        .onAppear { searchFocused = true }
        .onChange(of: query) { highlightedID = selectableChats.first?.id }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            NucleoIconView(.chats, size: 14)
                .foregroundStyle(Color.accentColor)
            Text("Chats")
                .font(PortlyTypography.bodyMedium)
            if let project {
                Text(project.name)
                    .font(PortlyTypography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let chats, !chats.isEmpty {
                Text("\(chats.count)")
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .accessibilityLabel("\(chats.count) chats")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            NucleoIconView(.search, size: 11)
                .foregroundStyle(.secondary)
            TextField("Search chats", text: $query)
                .textFieldStyle(.plain)
                .font(PortlyTypography.body)
                .focused($searchFocused)
                .onSubmit(resumeHighlighted)
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onExitCommand { ToolbarPopover.dismiss() }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    NucleoIconView(.xmarkCircle, size: 11)
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if chats == nil {
            placeholder(icon: nil, title: "Reading the conversations…", detail: nil)
        } else if chats?.isEmpty == true {
            placeholder(
                icon: .chats,
                title: "No past chats here yet",
                detail: "Every conversation Claude Code has in this project lands here, to resume whenever you want."
            )
        } else if visibleChats.isEmpty {
            placeholder(icon: .search, title: "No chat matches “\(query)”", detail: nil)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(ChatHistory.grouped(visibleChats), id: \.period) { group in
                        Text(group.period.title.uppercased())
                            .font(PortlyTypography.label)
                            .foregroundStyle(.tertiary)
                            .kerning(0.6)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.chats) { chat in
                            ChatHistoryRow(
                                chat: chat,
                                place: place(of: chat),
                                isHighlighted: highlightedID == chat.id
                            ) {
                                resume(chat)
                            }
                            .id(chat.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: Self.listHeight)
            .onChange(of: highlightedID) {
                guard let id = highlightedID else { return }
                withAnimation(Motion.hover) { scroller.scrollTo(id) }
            }
        }
    }

    private func placeholder(icon: AppIcon?, title: String, detail: String?) -> some View {
        VStack(spacing: 7) {
            if let icon {
                NucleoIconView(icon, size: 20)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
                .font(PortlyTypography.bodyMedium)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(PortlyTypography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .frame(height: 170)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Resumes in the focused terminal")
                .font(PortlyTypography.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 3) {
                KeyCap("↑")
                KeyCap("↓")
                KeyCap("↩")
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    // MARK: - Behaviour

    private func load() async {
        guard let root = project?.root else {
            chats = []
            return
        }
        let found = await Task.detached(priority: .userInitiated) {
            (chats: ClaudeChats.list(projectRoot: root), running: ClaudeChats.runningConversationIDs())
        }.value
        running = found.running
        chats = found.chats
        highlightedID = selectableChats.first?.id
    }

    private func place(of chat: ClaudeChat) -> ChatHistoryRow.Place {
        if let open = workspace.location(ofChat: chat.id) {
            return open.sessionID == sessionID && open.paneID == session?.focusedPaneID ? .here : .open
        }
        return running.contains(chat.id) ? .elsewhere : .closed
    }

    private func moveHighlight(by offset: Int) {
        let ids = selectableChats.map(\.id)
        guard !ids.isEmpty else { return }
        let current = highlightedID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        highlightedID = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    private func resumeHighlighted() {
        guard let chat = selectableChats.first(where: { $0.id == highlightedID }) ?? selectableChats.first else { return }
        resume(chat)
    }

    private func resume(_ chat: ClaudeChat) {
        ToolbarPopover.dismiss()
        workspace.resumeChat(chat, fromSession: sessionID)
    }
}

/// One past chat: its title, the last thing you asked, when, and where it is
/// open if it is.
private struct ChatHistoryRow: View {
    enum Place {
        /// In the focused terminal of this session.
        case here
        /// In another Portly terminal: picking it shows that terminal.
        case open
        /// Run by Claude Code in a terminal outside Portly.
        case elsewhere
        case closed
    }

    let chat: ClaudeChat
    let place: Place
    let isHighlighted: Bool
    let action: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if isHighlighted { return Color.accentColor.opacity(0.14) }
        return Color.primary.opacity(hovering && place != .elsewhere ? 0.06 : 0)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(PortlyTypography.bodyMedium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let prompt = chat.lastPrompt, prompt != chat.title {
                        Text(prompt)
                            .font(PortlyTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Self.timeLabel(chat.lastExchange))
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    if let badge {
                        Text(badge)
                            .font(PortlyTypography.label)
                            .foregroundStyle(place == .elsewhere ? Color.secondary : Color.accentColor)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(
                                (place == .elsewhere ? Color.primary : Color.accentColor).opacity(0.12),
                                in: Capsule()
                            )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(place == .elsewhere ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(place == .elsewhere)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(help)
        .accessibilityLabel([chat.title, Self.timeLabel(chat.lastExchange), badge].compactMap { $0 }.joined(separator: ", "))
    }

    private var badge: String? {
        switch place {
        case .here: return "HERE"
        case .open: return "OPEN"
        case .elsewhere: return "ELSEWHERE"
        case .closed: return nil
        }
    }

    private var help: String {
        switch place {
        case .here: return "Running in the focused terminal"
        case .open: return "Open in another Portly terminal: show it"
        case .elsewhere: return "Claude Code runs it in another terminal. Quit it there to resume it here."
        case .closed: return "Resume this chat in the focused terminal"
        }
    }

    /// The time for today and yesterday (the section says which day), the
    /// weekday within the week, the date beyond, with the year once it is
    /// not this one.
    static func timeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch ChatHistory.period(of: date, now: now, calendar: calendar) {
        case .today, .yesterday:
            return date.formatted(date: .omitted, time: .shortened)
        case .previousWeek:
            return date.formatted(.dateTime.weekday(.abbreviated))
        case .previousMonth, .older:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return sameYear
                ? date.formatted(.dateTime.day().month(.abbreviated))
                : date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }
}
