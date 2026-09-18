import PortlyCore
import SwiftUI

/// The button beside the sidebar search, and the list it opens: every project,
/// the ones put away first, searchable by name. Picking one brings it back to
/// the sidebar and opens a coding session on it.
struct OlderProjectsButton: View {
    /// Projects the sidebar is not showing right now.
    let hidden: [Project]
    /// Projects it is showing, offered below the others so one list finds all.
    let listed: [Project]
    let lastActivity: (String) -> Date?
    let onPick: (Project) -> Void

    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            NucleoIconView(.history, size: 13)
                .foregroundStyle(hidden.isEmpty ? Color.secondary : Color.primary.opacity(0.8))
                .frame(width: 28, height: 28)
                .background {
                    // Same radius and fill as the search field it sits beside.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering || showing ? 0.1 : 0.055))
                }
                .overlay(alignment: .topTrailing) {
                    if !hidden.isEmpty {
                        Text("\(hidden.count)")
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
        .animation(Motion.state, value: hidden.count)
        .help(hidden.isEmpty
            ? "All projects are in the sidebar. Projects untouched for a day move here."
            : "\(hidden.count) older project\(hidden.count == 1 ? "" : "s"): no server running and nothing done in the last day")
        .accessibilityLabel("Older projects")
        .accessibilityValue("\(hidden.count) hidden")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            OlderProjectsList(hidden: hidden, listed: listed, lastActivity: lastActivity) { project in
                showing = false
                onPick(project)
            }
        }
    }
}

private struct OlderProjectsList: View {
    let hidden: [Project]
    let listed: [Project]
    let lastActivity: (String) -> Date?
    let onPick: (Project) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    private var hiddenMatches: [Project] {
        SidebarVisibility.search(hidden, query: query, lastActivity: lastActivity)
    }

    private var listedMatches: [Project] {
        SidebarVisibility.search(listed, query: query, lastActivity: lastActivity)
    }

    private var ordered: [Project] { hiddenMatches + listedMatches }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                NucleoIconView(.search, size: 13)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Find a project", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(pickHighlighted)
                    .accessibilityLabel("Find a project by name")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)

            Divider()

            if ordered.isEmpty {
                VStack(spacing: 6) {
                    NucleoIconView(.search, size: 20)
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "No projects yet" : "No project named “\(query)”")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            section("Older", projects: hiddenMatches)
                            section("In the sidebar", projects: listedMatches)
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: highlighted) {
                        guard let highlighted else { return }
                        proxy.scrollTo(highlighted)
                    }
                }
            }
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

    @ViewBuilder
    private func section(_ title: String, projects: [Project]) -> some View {
        if !projects.isEmpty {
            Text(title.uppercased())
                .font(PortlyTypography.label)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(projects) { project in
                OlderProjectRow(
                    project: project,
                    lastActivity: lastActivity(project.id),
                    isHighlighted: highlighted == project.id
                ) {
                    onPick(project)
                }
                .id(project.id)
                .onHover { if $0 { highlighted = project.id } }
            }
        }
    }

    private func move(_ offset: Int) {
        let ids = ordered.map(\.id)
        guard !ids.isEmpty else { return }
        let current = highlighted.flatMap { ids.firstIndex(of: $0) } ?? -1
        highlighted = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    private func pickHighlighted() {
        guard let project = ordered.first(where: { $0.id == highlighted }) ?? ordered.first else { return }
        onPick(project)
    }
}

private struct OlderProjectRow: View {
    let project: Project
    let lastActivity: Date?
    let isHighlighted: Bool
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
                if isHighlighted {
                    NucleoIconView(.returnKey, size: 10)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
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
