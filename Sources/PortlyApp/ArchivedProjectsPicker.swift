import PortlyCore
import SwiftUI

/// The button beside the sidebar search, and the list it opens: every project,
/// the archived ones first, searchable by name. Picking one brings it back to
/// the sidebar and opens a coding session on it.
struct ArchivedProjectsButton: View {
    /// Projects in the archive.
    let archived: [Project]
    /// Projects in the sidebar, offered below the others so one list finds all.
    let listed: [Project]
    let lastActivity: (String) -> Date?
    let isRunning: (Project) -> Bool
    /// Bring back and open a session.
    let onOpen: (Project) -> Void
    /// Bring back to the sidebar without opening anything.
    let onRestore: (Project) -> Void
    let onArchive: (Project) -> Void

    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            NucleoIconView(.archive, size: 13)
                .foregroundStyle(archived.isEmpty ? Color.secondary : Color.primary.opacity(0.8))
                .frame(width: 28, height: 28)
                .background {
                    // Same radius and fill as the search field it sits beside.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering || showing ? 0.1 : 0.055))
                }
                .overlay(alignment: .topTrailing) {
                    if !archived.isEmpty {
                        Text("\(archived.count)")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 4, y: -4)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.state, value: archived.count)
        .help(archived.isEmpty
            ? "Archived projects. Right-click a project in the sidebar to archive it."
            : "\(archived.count) archived project\(archived.count == 1 ? "" : "s")")
        .accessibilityLabel("Archived projects")
        .accessibilityValue("\(archived.count) archived")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ArchivedProjectsList(
                archived: archived,
                listed: listed,
                lastActivity: lastActivity,
                isRunning: isRunning,
                onOpen: { project in
                    showing = false
                    onOpen(project)
                },
                onRestore: onRestore,
                onArchive: onArchive
            )
        }
    }
}

private struct ArchivedProjectsList: View {
    let archived: [Project]
    let listed: [Project]
    let lastActivity: (String) -> Date?
    let isRunning: (Project) -> Bool
    let onOpen: (Project) -> Void
    let onRestore: (Project) -> Void
    let onArchive: (Project) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 1
    private static let sectionHeaderHeight: CGFloat = 22
    private static let listPadding: CGFloat = 6
    private static let minimumListHeight: CGFloat = 150
    private static let maximumListHeight: CGFloat = 380

    private var archivedMatches: [Project] {
        SidebarVisibility.search(archived, query: query, lastActivity: lastActivity)
    }

    private var listedMatches: [Project] {
        SidebarVisibility.search(listed, query: query, lastActivity: lastActivity)
    }

    private var ordered: [Project] { archivedMatches + listedMatches }

    /// Sized from every project, not from the current matches: the popover
    /// keeps its height while you type, and a search that found nothing
    /// cannot leave it shrunken the next time it opens.
    private var listHeight: CGFloat {
        let sections = [archived, listed].filter { !$0.isEmpty }.count
        let rows = archived.count + listed.count
        let content = Self.listPadding * 2
            + CGFloat(sections) * Self.sectionHeaderHeight
            + CGFloat(rows) * (Self.rowHeight + Self.rowSpacing)
        return min(max(content, Self.minimumListHeight), Self.maximumListHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                NucleoIconView(.search, size: 13)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Find a project", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(openHighlighted)
                    .accessibilityLabel("Find a project by name")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)

            Divider()

            Group {
                if ordered.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(height: listHeight)

            Divider()

            Text("Right-click a project to archive it or bring it back.")
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 26)
        }
        .frame(width: 320)
        .onAppear {
            searchFocused = true
            highlighted = ordered.first?.id
        }
        .onChange(of: query) { highlighted = ordered.first?.id }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            NucleoIconView(.search, size: 20)
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No projects yet" : "No project named “\(query)”")
                .font(PortlyTypography.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                    section("Archived", projects: archivedMatches, isArchived: true)
                    section("In the sidebar", projects: listedMatches, isArchived: false)
                }
                .padding(Self.listPadding)
            }
            .onChange(of: highlighted) {
                guard let highlighted else { return }
                proxy.scrollTo(highlighted)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, projects: [Project], isArchived: Bool) -> some View {
        if !projects.isEmpty {
            Text(title.uppercased())
                .font(PortlyTypography.label)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .frame(height: Self.sectionHeaderHeight, alignment: .bottomLeading)
            ForEach(projects) { project in
                ArchivedProjectRow(
                    project: project,
                    lastActivity: lastActivity(project.id),
                    isRunning: isRunning(project),
                    isHighlighted: highlighted == project.id,
                    height: Self.rowHeight
                ) {
                    onOpen(project)
                }
                .id(project.id)
                .onHover { if $0 { highlighted = project.id } }
                .contextMenu {
                    Button("Open Coding Session") { onOpen(project) }
                    if isArchived {
                        Button("Bring Back to Sidebar") { onRestore(project) }
                    } else {
                        Button("Archive Project") { onArchive(project) }
                    }
                }
            }
        }
    }

    private func move(_ offset: Int) {
        let ids = ordered.map(\.id)
        guard !ids.isEmpty else { return }
        let current = highlighted.flatMap { ids.firstIndex(of: $0) } ?? -1
        highlighted = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    private func openHighlighted() {
        guard let project = ordered.first(where: { $0.id == highlighted }) ?? ordered.first else { return }
        onOpen(project)
    }
}

private struct ArchivedProjectRow: View {
    let project: Project
    let lastActivity: Date?
    let isRunning: Bool
    let isHighlighted: Bool
    let height: CGFloat
    let action: () -> Void

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var subtitle: String {
        let servers = project.servers.count
        let serverText = servers == 1 ? "1 server" : "\(servers) servers"
        guard let lastActivity else { return serverText }
        return "\(Self.relative.localizedString(for: lastActivity, relativeTo: Date())) · \(serverText)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                NucleoIconView(LegacyProjectIcons.resolve(project.icon), size: 12)
                    .foregroundStyle(Color(hex: project.color))
                    .frame(width: 22, height: 22)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(hex: project.color).opacity(0.14))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(PortlyTypography.bodyMedium)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if isRunning {
                    Circle()
                        .fill(ServerState.running.color)
                        .frame(width: 6, height: 6)
                        .help("A server is running")
                        .accessibilityLabel("Server running")
                }
                if isHighlighted {
                    NucleoIconView(.returnKey, size: 10)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(isHighlighted ? 0.14 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSString(string: project.root).abbreviatingWithTildeInPath)
        .accessibilityLabel("Open \(project.name)")
        .accessibilityHint("Brings the project back to the sidebar and opens a coding session")
    }
}
