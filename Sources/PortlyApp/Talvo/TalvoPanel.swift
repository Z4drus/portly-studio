import AppKit
import PortlyCore
import SwiftUI

/// The Talvo project a Portly project mirrors, over the detail area: its
/// issues by status on the left, the selected issue or document on the
/// right, and the project itself (description, milestones, members, links,
/// updates, documents) one tab away. Everything here reads the shared
/// workspace copy, so a change made in Talvo shows as it happens.
struct TalvoPanel: View {
    let project: Project
    let talvoProjectID: String

    @ObservedObject private var center = TalvoCenter.shared
    @ObservedObject private var workspace = StudioWorkspace.shared

    enum Tab: Hashable { case issues, project }

    enum Selection: Hashable {
        case issue(String)
        case document(String)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case open, all, mine, urgent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .open: return "Open"
            case .all: return "All"
            case .mine: return "Mine"
            case .urgent: return "Urgent"
            }
        }
    }

    @State private var tab: Tab = .issues
    @State private var selection: Selection?
    @State private var query = ""
    @State private var filter: Filter = .open

    private static let listWidth: CGFloat = 380

    private var talvoProject: TalvoProject? { center.data.projects[talvoProjectID] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                leftColumn
                    .frame(width: Self.listWidth)
                Divider()
                rightColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .task(id: talvoProjectID) {
            await center.loadProjectDetail(talvoProjectID)
        }
        .environment(\.openURL, OpenURLAction(handler: open))
        .onExitCommand { workspace.talvoPanelProjectID = nil }
    }

    /// Links in Talvo text: a relative one points into Talvo itself, and an
    /// issue link opens the issue here rather than in the browser.
    private func open(_ url: URL) -> OpenURLAction.Result {
        let resolved = url.host == nil ? center.publicURL.flatMap { URL(string: url.relativeString, relativeTo: $0)?.absoluteURL } : url
        guard let resolved else { return .discarded }
        if let issueID = center.issueID(linkedBy: resolved) {
            selection = .issue(issueID)
            return .handled
        }
        TalvoLinks.open(resolved)
        return .handled
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let talvoProject {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(hex: talvoProject.color).opacity(0.14))
                    NucleoIconView(TalvoIcons.glyph(for: talvoProject.icon, fallback: .talvo), size: 18)
                        .foregroundStyle(Color(hex: talvoProject.color))
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(talvoProject.name)
                            .font(PortlyTypography.title)
                            .lineLimit(1)
                        TalvoChip(text: talvoProject.status.label, color: talvoProject.status.color)
                        if let health = talvoProject.health {
                            TalvoChip(text: health.label, color: health.color)
                        }
                        if talvoProject.priority != .none {
                            HStack(spacing: 4) {
                                TalvoPriorityGlyph(priority: talvoProject.priority, size: 11)
                                Text(talvoProject.priority.label)
                                    .font(PortlyTypography.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        if let summary = talvoProject.summary, !summary.isEmpty {
                            Text(summary)
                                .font(PortlyTypography.metadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let target = TalvoDates.shortDay(talvoProject.targetDate) {
                            let late = TalvoDates.isPast(talvoProject.targetDate) && talvoProject.status != .completed
                            NucleoLabel("Target \(target)", icon: .milestone, size: 10)
                                .font(PortlyTypography.metadata)
                                .foregroundStyle(late ? Color.red : Color.secondary)
                        }
                        if let lead = talvoProject.leadId.flatMap({ center.data.users[$0] }) {
                            HStack(spacing: 4) {
                                TalvoAvatar(user: lead, size: 14)
                                Text(lead.name)
                                    .font(PortlyTypography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                TalvoProgressBar(progress: center.data.progress(ofProject: talvoProject.id), color: Color(hex: talvoProject.color))
                    .frame(width: 160)
            } else {
                NucleoIconView(.talvo, size: 18)
                    .foregroundStyle(.secondary)
                Text("This Talvo project is no longer visible to your token.")
                    .font(PortlyTypography.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let talvoProject, let url = center.webURL(forProject: talvoProject) {
                headerButton(.externalLink, help: "Open \(talvoProject.name) in Talvo") {
                    NSWorkspace.shared.open(url)
                }
            }
            Menu {
                Button("Refresh") {
                    Task { await center.loadProjectDetail(talvoProjectID, force: true) }
                    center.reconnectNow()
                }
                Divider()
                Button("Unlink from Talvo") {
                    workspace.linkTalvoProject(nil, to: project.id)
                }
            } label: {
                NucleoIconView(.dots, size: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("More")
            headerButton(.xmark, help: "Close (Esc)") {
                workspace.talvoPanelProjectID = nil
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    private func headerButton(_ icon: AppIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIconView(icon, size: 13)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Text("Issues · \(center.data.openIssueCount(inProject: talvoProjectID))").tag(Tab.issues)
                    Text("Project").tag(Tab.project)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .issues: issuesList
            case .project: projectTab
            }
        }
    }

    private var issuesList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    NucleoIconView(.search, size: 11)
                        .foregroundStyle(.tertiary)
                    TextField("Search issues", text: $query)
                        .textFieldStyle(.plain)
                        .font(PortlyTypography.body)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 92)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            let groups = groupedIssues
            if groups.isEmpty {
                VStack(spacing: 6) {
                    NucleoIconView(.checkCircle, size: 20)
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "Nothing here" : "No issue matches")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectedIssueBinding) {
                    ForEach(groups, id: \.status.id) { group in
                        Section {
                            ForEach(group.issues) { issue in
                                TalvoIssueRow(issue: issue)
                                    .tag(issue.id)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            }
                        } header: {
                            HStack(spacing: 6) {
                                TalvoStatusGlyph(status: group.status, size: 11)
                                Text(group.status.name)
                                    .font(PortlyTypography.label)
                                    .foregroundStyle(.secondary)
                                Text("\(group.issues.count)")
                                    .font(PortlyTypography.label)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private struct IssueGroup {
        var status: TalvoStatus
        var issues: [TalvoIssue]
    }

    /// Issues of the project that pass the filter and the search, grouped by
    /// status in Talvo's order, urgent first inside a group.
    private var groupedIssues: [IssueGroup] {
        let data = center.data
        let me = data.me?.id
        let needle = TalvoSearch.fold(query)
        let issues = data.issues(inProject: talvoProjectID).filter { issue in
            let type = data.statuses[issue.statusId]?.type ?? .backlog
            switch filter {
            case .all: break
            case .open: guard type.isOpen else { return false }
            case .mine: guard issue.assigneeId == me, type.isOpen else { return false }
            case .urgent: guard issue.priority == .urgent, type.isOpen else { return false }
            }
            guard !needle.isEmpty else { return true }
            return TalvoSearch.fold(issue.title).contains(needle)
                || TalvoSearch.fold(data.identifier(for: issue)).contains(needle)
                || String(issue.number) == needle
        }
        return data.orderedStatuses.compactMap { status in
            let inStatus = issues
                .filter { $0.statusId == status.id }
                .sorted { lhs, rhs in
                    if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                    return lhs.updatedAt > rhs.updatedAt
                }
            return inStatus.isEmpty ? nil : IssueGroup(status: status, issues: inStatus)
        }
    }

    private var selectedIssueBinding: Binding<String?> {
        Binding(
            get: {
                if case .issue(let id)? = selection { return id }
                return nil
            },
            set: { id in
                if let id { selection = .issue(id) }
            }
        )
    }

    // MARK: Project tab

    private var projectTab: some View {
        let detail = center.projectDetails[talvoProjectID]
        let data = center.data
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let detail {
                    section("Description", icon: .document) {
                        if detail.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No description yet.")
                                .font(PortlyTypography.body)
                                .foregroundStyle(.tertiary)
                        } else {
                            MarkdownView(markdown: detail.description)
                        }
                    }
                } else if let error = center.detailErrors[talvoProjectID] {
                    Text(error)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the project…")
                            .font(PortlyTypography.body)
                            .foregroundStyle(.secondary)
                    }
                }

                let milestones = data.milestones(inProject: talvoProjectID)
                if !milestones.isEmpty {
                    section("Milestones", icon: .milestone) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(milestones) { milestone in
                                let issues = data.issues(inProject: talvoProjectID).filter { $0.milestoneId == milestone.id }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(milestone.name)
                                            .font(PortlyTypography.bodyMedium)
                                            .lineLimit(1)
                                        Spacer()
                                        if let target = TalvoDates.shortDay(milestone.targetDate) {
                                            Text(target)
                                                .font(PortlyTypography.metadata)
                                                .foregroundStyle(TalvoDates.isPast(milestone.targetDate) ? Color.red : Color.secondary)
                                        }
                                    }
                                    TalvoProgressBar(progress: data.progress(of: issues))
                                }
                            }
                        }
                    }
                }

                let memberIDs = detail?.memberIds ?? data.memberIDs(ofProject: talvoProjectID)
                if !memberIDs.isEmpty {
                    section("Members", icon: .userGroup) {
                        FlowLayout(spacing: 8) {
                            ForEach(memberIDs, id: \.self) { id in
                                HStack(spacing: 5) {
                                    TalvoAvatar(user: data.users[id], size: 16)
                                    Text(data.users[id]?.name ?? "Unknown")
                                        .font(PortlyTypography.body)
                                }
                                .padding(.trailing, 4)
                            }
                        }
                    }
                }

                let links = detail?.links ?? data.links(inProject: talvoProjectID)
                if !links.isEmpty {
                    section("Links", icon: .externalLink) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(links) { link in
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

                if let updates = detail?.updates, !updates.isEmpty {
                    section("Updates", icon: .chat) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(updates.prefix(5)) { update in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        TalvoChip(text: update.health.label, color: update.health.color)
                                        Text(update.authorName)
                                            .font(PortlyTypography.metadata)
                                            .foregroundStyle(.secondary)
                                        Text(talvoAge(update.createdAt))
                                            .font(PortlyTypography.metadata)
                                            .foregroundStyle(.tertiary)
                                    }
                                    MarkdownView(markdown: update.body)
                                }
                            }
                        }
                    }
                }

                let documents = data.documents(inProject: talvoProjectID)
                if !documents.isEmpty {
                    section("Documents", icon: .files) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(documents) { document in
                                Button {
                                    selection = .document(document.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        NucleoIconView(TalvoIcons.glyph(for: document.icon, fallback: .file), size: 12)
                                            .foregroundStyle(document.color.map { Color(hex: $0) } ?? Color.secondary)
                                        Text(document.title)
                                            .font(PortlyTypography.body)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(talvoAge(document.updatedAt))
                                            .font(PortlyTypography.metadata)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .background(
                                        selection == .document(document.id) ? Color.accentColor.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(14)
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

    // MARK: Right column

    @ViewBuilder
    private var rightColumn: some View {
        switch selection {
        case .issue(let id)?:
            TalvoIssueDetailView(issueID: id) { other in selection = .issue(other) }
                .id(id)
        case .document(let id)?:
            TalvoDocumentView(documentID: id)
                .id(id)
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        let data = center.data
        let issues = data.issues(inProject: talvoProjectID)
        return VStack(spacing: 14) {
            if let talvoProject {
                NucleoIconView(TalvoIcons.glyph(for: talvoProject.icon, fallback: .talvo), size: 34)
                    .foregroundStyle(Color(hex: talvoProject.color).opacity(0.7))
            }
            Text("Select an issue to read it here")
                .font(PortlyTypography.body)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(data.orderedStatuses) { status in
                    let count = issues.filter { $0.statusId == status.id }.count
                    if count > 0 {
                        HStack(spacing: 5) {
                            TalvoStatusGlyph(status: status, size: 11)
                            Text("\(count)")
                                .font(PortlyTypography.metric)
                                .monospacedDigit()
                            Text(status.name)
                                .font(PortlyTypography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Issue row

/// One line of the list: priority, identifier, title, labels, due date, who.
struct TalvoIssueRow: View {
    let issue: TalvoIssue

    @ObservedObject private var center = TalvoCenter.shared

    var body: some View {
        let data = center.data
        let overdue = TalvoDates.isPast(issue.dueDate) && (data.statuses[issue.statusId]?.type.isOpen ?? true)
        HStack(spacing: 8) {
            TalvoPriorityGlyph(priority: issue.priority, size: 11)
            Text(data.identifier(for: issue))
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Text(issue.title)
                .font(PortlyTypography.body)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            ForEach(issue.labelIds.prefix(2), id: \.self) { labelID in
                if let label = data.labels[labelID] {
                    TalvoChip(text: label.name, color: Color(hex: label.color))
                }
            }
            if overdue, let due = TalvoDates.shortDay(issue.dueDate) {
                TalvoChip(text: due, color: .red, icon: .clock)
            }
            TalvoAvatar(user: issue.assigneeId.flatMap { data.users[$0] }, size: 16)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(issue.title)
    }
}

// MARK: - Document

/// A Talvo document, read when opened.
struct TalvoDocumentView: View {
    let documentID: String

    @ObservedObject private var center = TalvoCenter.shared
    @State private var detail: TalvoDocumentDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let detail {
                    HStack(spacing: 10) {
                        NucleoIconView(TalvoIcons.glyph(for: detail.icon, fallback: .file), size: 16)
                            .foregroundStyle(detail.color.map { Color(hex: $0) } ?? Color.secondary)
                        Text(detail.title)
                            .font(PortlyTypography.title)
                            .textSelection(.enabled)
                        Spacer()
                        Text("Updated \(talvoAge(detail.updatedAt))")
                            .font(PortlyTypography.metadata)
                            .foregroundStyle(.tertiary)
                    }
                    Divider()
                    MarkdownView(markdown: detail.content)
                } else if let error {
                    Text(error)
                        .font(PortlyTypography.body)
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the document…")
                            .font(PortlyTypography.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: documentID) { await load() }
        .onChange(of: center.data.documents[documentID]?.updatedAt) { Task { await load() } }
    }

    private func load() async {
        do {
            detail = try await center.loadDocument(documentID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
