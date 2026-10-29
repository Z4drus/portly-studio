import AppKit
import SwiftUI

/// What the Talvo views type into the focused terminal.
enum TalvoAgentMessages {
    /// Hand an issue to the agent: it has the Talvo tools to read the rest.
    static func workOn(identifier: String, title: String) -> String {
        "Peux-tu regarder l'issue \(identifier) sur Talvo (« \(title) ») et t'en occuper ? "
    }
}

/// One issue in full: its properties, description, sub-issues, relations,
/// links, comments and activity, read from Talvo when opened and refreshed
/// when a delta says it moved.
struct TalvoIssueDetailView: View {
    let issueID: String
    let onSelectIssue: (String) -> Void

    @ObservedObject private var center = TalvoCenter.shared
    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var draftComment = ""
    @State private var sending = false
    @State private var actionError: String?

    private var issue: TalvoIssue? { center.data.issues[issueID] }
    private var detail: TalvoIssueDetail? { center.issueDetails[issueID] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let issue {
                    topBar(issue)
                    Text(detail?.title ?? issue.title)
                        .font(PortlyTypography.title)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    properties(issue)
                    descriptionSection
                    if let detail {
                        if !detail.children.isEmpty { children(detail) }
                        if !detail.relations.isEmpty { relations(detail) }
                        if !detail.links.isEmpty { links(detail) }
                        comments(detail)
                        if !detail.activity.isEmpty { activity(detail) }
                    } else if let error = center.detailErrors[issueID] {
                        Text(error)
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(.red)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the issue…")
                                .font(PortlyTypography.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("This issue is no longer visible.")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }
                if let actionError {
                    Text(actionError)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.red)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: issueID) { await center.loadIssueDetail(issueID) }
    }

    // MARK: Top bar

    private func topBar(_ issue: TalvoIssue) -> some View {
        let data = center.data
        let identifier = data.identifier(for: issue)
        return HStack(spacing: 10) {
            Text(identifier)
                .font(PortlyTypography.metric)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            statusControl(issue)
            HStack(spacing: 4) {
                TalvoPriorityGlyph(priority: issue.priority, size: 11)
                Text(issue.priority.label)
                    .font(PortlyTypography.label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                // The panel covers the terminal: step aside so the typed
                // request is seen landing, and so Esc goes to the terminal.
                workspace.talvoPanelProjectID = nil
                workspace.insertIntoFocusedTerminal(TalvoAgentMessages.workOn(identifier: identifier, title: issue.title))
            } label: {
                NucleoLabel("Tell the agent", icon: .paperPlane, size: 11)
            }
            .controlSize(.small)
            .disabled(!canTellAgent)
            .help(canTellAgent
                ? "Type a request about \(identifier) into the focused terminal"
                : "Open a coding session to hand this issue to an agent")
            if let url = center.webURL(forIssueIdentifier: identifier) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    NucleoIconView(.externalLink, size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(identifier) in Talvo")
                .accessibilityLabel("Open in Talvo")
            }
        }
    }

    private var canTellAgent: Bool { workspace.canInsertIntoFocusedTerminal }

    /// The status as a chip; a menu over the statuses when the token may write.
    @ViewBuilder
    private func statusControl(_ issue: TalvoIssue) -> some View {
        let status = center.data.statuses[issue.statusId]
        let chip = HStack(spacing: 5) {
            TalvoStatusGlyph(status: status, size: 11)
            Text(status?.name ?? "Unknown")
                .font(PortlyTypography.label)
        }
        .foregroundStyle(status.map { Color(hex: $0.color) } ?? Color.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background((status.map { Color(hex: $0.color) } ?? Color.secondary).opacity(0.12), in: Capsule(style: .continuous))
        if center.canWrite {
            Menu {
                ForEach(center.data.orderedStatuses) { candidate in
                    Button {
                        change(issue: issue.id, to: candidate.id)
                    } label: {
                        Label {
                            Text(candidate.name)
                        } icon: {
                            if candidate.id == issue.statusId { NucleoIconView(.check, size: 10) }
                        }
                    }
                }
            } label: {
                chip
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change the status in Talvo")
        } else {
            chip
        }
    }

    private func change(issue id: String, to statusID: String) {
        Task {
            do {
                try await center.setStatus(ofIssue: id, to: statusID)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: Properties

    private func properties(_ issue: TalvoIssue) -> some View {
        let data = center.data
        return FlowLayout(spacing: 8) {
            property(icon: .user, text: issue.assigneeId.flatMap { data.users[$0]?.name } ?? "Unassigned", muted: issue.assigneeId == nil) {
                TalvoAvatar(user: issue.assigneeId.flatMap { data.users[$0] }, size: 14)
            }
            if let milestone = issue.milestoneId.flatMap({ data.milestones[$0] }) {
                property(icon: .milestone, text: milestone.name)
            }
            ForEach(issue.labelIds, id: \.self) { id in
                if let label = data.labels[id] {
                    TalvoChip(text: label.name, color: Color(hex: label.color))
                        .frame(height: 24)
                }
            }
            if let due = TalvoDates.shortDay(issue.dueDate) {
                let late = TalvoDates.isPast(issue.dueDate) && (data.statuses[issue.statusId]?.type.isOpen ?? true)
                property(icon: .clock, text: "Due \(due)", tint: late ? .red : nil)
            }
            if let estimate = issue.estimate {
                property(icon: .hashtag, text: estimate == estimate.rounded() ? "\(Int(estimate)) pt" : "\(estimate) pt")
            }
            if let parent = detail?.parent {
                Button {
                    onSelectIssue(parent.id)
                } label: {
                    property(icon: .arrowUp, text: "\(parent.identifier) · \(parent.title)", tint: .accentColor)
                }
                .buttonStyle(.plain)
                .help("Open the parent issue")
            }
            property(icon: .history, text: "Updated \(talvoAge(issue.updatedAt)) · created \(talvoAge(issue.createdAt))", muted: true)
        }
    }

    private func property<Leading: View>(
        icon: AppIcon,
        text: String,
        tint: Color? = nil,
        muted: Bool = false,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 5) {
            leading()
            Text(text)
                .font(PortlyTypography.metadata)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260)
        }
        .foregroundStyle(tint ?? (muted ? Color.secondary : Color.primary.opacity(0.85)))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
    }

    private func property(icon: AppIcon, text: String, tint: Color? = nil, muted: Bool = false) -> some View {
        property(icon: icon, text: text, tint: tint, muted: muted) {
            NucleoIconView(icon, size: 10)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var descriptionSection: some View {
        if let detail {
            if detail.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description.")
                    .font(PortlyTypography.body)
                    .foregroundStyle(.tertiary)
            } else {
                MarkdownView(markdown: detail.description)
            }
        }
    }

    private func children(_ detail: TalvoIssueDetail) -> some View {
        let data = center.data
        let done = detail.children.filter { data.statuses[$0.statusId]?.type == .completed }.count
        return section("Sub-issues · \(done)/\(detail.children.count)", icon: .layers) {
            VStack(spacing: 2) {
                ForEach(detail.children) { child in
                    Button {
                        onSelectIssue(child.id)
                    } label: {
                        HStack(spacing: 8) {
                            TalvoStatusGlyph(status: data.statuses[child.statusId], size: 11)
                            Text(data.identifier(for: child))
                                .font(PortlyTypography.metadata)
                                .foregroundStyle(.tertiary)
                            Text(child.title)
                                .font(PortlyTypography.body)
                                .lineLimit(1)
                                .strikethrough(child.archivedAt != nil)
                            Spacer()
                            TalvoAvatar(user: child.assigneeId.flatMap { data.users[$0] }, size: 14)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func relations(_ detail: TalvoIssueDetail) -> some View {
        let data = center.data
        return section("Relations", icon: .gitMerge) {
            FlowLayout(spacing: 6) {
                ForEach(detail.relations) { relation in
                    let otherID = relation.issueId == issueID ? relation.relatedId : relation.issueId
                    let other = data.issues[otherID]
                    let verb = relationVerb(relation)
                    Button {
                        onSelectIssue(otherID)
                    } label: {
                        HStack(spacing: 5) {
                            Text(verb)
                                .foregroundStyle(verb == "blocked by" ? Color.red : Color.secondary)
                            Text(other.map { data.identifier(for: $0) } ?? "?")
                                .foregroundStyle(Color.accentColor)
                            if let other {
                                Text(other.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: 220)
                            }
                        }
                        .font(PortlyTypography.metadata)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// How this issue stands to the other one in a relation.
    private func relationVerb(_ relation: TalvoRelation) -> String {
        switch relation.type {
        case "blocks": return relation.issueId == issueID ? "blocks" : "blocked by"
        case "duplicate": return "duplicate of"
        default: return "related to"
        }
    }

    private func links(_ detail: TalvoIssueDetail) -> some View {
        section("Links", icon: .externalLink) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.links) { link in
                    Button {
                        TalvoLinks.open(link.url)
                    } label: {
                        HStack(spacing: 6) {
                            NucleoIconView(.externalLink, size: 10)
                            Text(link.title)
                                .lineLimit(1)
                        }
                        .font(PortlyTypography.body)
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(link.url)
                }
            }
        }
    }

    private func comments(_ detail: TalvoIssueDetail) -> some View {
        let data = center.data
        return section("Comments · \(detail.comments.count)", icon: .chat) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(detail.comments) { comment in
                    HStack(alignment: .top, spacing: 10) {
                        TalvoAvatar(user: comment.authorId.flatMap { data.users[$0] }, size: 22)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(comment.authorName)
                                    .font(PortlyTypography.bodyMedium)
                                Text(talvoAge(comment.createdAt))
                                    .font(PortlyTypography.metadata)
                                    .foregroundStyle(.tertiary)
                                if comment.parentId != nil {
                                    Text("reply")
                                        .font(PortlyTypography.label)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            MarkdownView(markdown: comment.body)
                        }
                    }
                    .padding(.leading, comment.parentId == nil ? 0 : 20)
                }
                if detail.comments.isEmpty {
                    Text("No comment yet.")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.tertiary)
                }
                if center.canWrite {
                    composer
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Write a comment…", text: $draftComment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(PortlyTypography.body)
                .lineLimit(1...6)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button(sending ? "Sending…" : "Comment") { sendComment() }
                .controlSize(.small)
                .disabled(sending || draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sendComment() {
        let body = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        Task {
            do {
                try await center.addComment(toIssue: issueID, body: body)
                draftComment = ""
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
            sending = false
        }
    }

    private func activity(_ detail: TalvoIssueDetail) -> some View {
        section("Activity", icon: .history) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(detail.activity.suffix(12).reversed()) { entry in
                    HStack(spacing: 6) {
                        Text(entry.actorName)
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(.secondary)
                        if let via = entry.via, !via.isEmpty {
                            Text("via \(via)")
                                .font(PortlyTypography.label)
                                .foregroundStyle(.tertiary)
                        }
                        Text(Self.describe(entry))
                            .font(PortlyTypography.metadata)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(talvoAge(entry.createdAt))
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// "status: À faire → En cours", from the kind and its `{from, to}`.
    static func describe(_ entry: TalvoActivity) -> String {
        let kind = entry.kind
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let from = entry.data["from"]?.displayText
        let to = entry.data["to"]?.displayText
        switch (from, to) {
        case let (from?, to?): return "\(kind): \(from) → \(to)"
        case let (nil, to?): return "\(kind): \(to)"
        case let (from?, nil): return "\(kind): \(from) removed"
        default: return kind
        }
    }

    private func section<Content: View>(_ title: String, icon: AppIcon, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                NucleoIconView(icon, size: 11)
                    .foregroundStyle(.tertiary)
                Text(title.uppercased())
                    .font(PortlyTypography.label)
                    .foregroundStyle(.tertiary)
                    .kerning(0.6)
            }
            content()
        }
    }
}
