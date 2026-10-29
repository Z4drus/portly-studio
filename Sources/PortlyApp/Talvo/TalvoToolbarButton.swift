import AppKit
import PortlyCore
import SwiftUI

/// The Talvo readout at the left of the toolbar, on every screen of a
/// project: the mirrored Talvo project's name, its open issues and the
/// urgent ones. Clicking a linked project opens its Talvo panel; clicking an
/// unlinked one offers the Talvo projects to link. Absent altogether when no
/// Talvo token is set on this Mac.
struct TalvoToolbarButton: View {
    let project: Project

    @ObservedObject private var center = TalvoCenter.shared
    @ObservedObject private var workspace = StudioWorkspace.shared

    private var linked: TalvoProject? {
        workspace.talvoProjectID(for: project.id).flatMap { center.data.projects[$0] }
    }

    var body: some View {
        Button {
            if linked != nil {
                workspace.toggleTalvoPanel(projectID: project.id)
            } else {
                let project = self.project
                ToolbarPopover.toggle(id: "talvo-link") {
                    TalvoLinkPicker(project: project)
                }
            }
        } label: {
            label
        }
        .help(helpText)
        .accessibilityLabel("Talvo")
        .accessibilityValue(linked.map { "\($0.name), \(center.data.openIssueCount(inProject: $0.id)) open issues" } ?? "Not linked")
    }

    @ViewBuilder
    private var label: some View {
        if let linked {
            let open = center.data.openIssueCount(inProject: linked.id)
            let urgent = center.data.urgentOpenIssueCount(inProject: linked.id)
            HStack(spacing: 7) {
                NucleoIconView(TalvoIcons.glyph(for: linked.icon, fallback: .talvo), size: 14)
                    .foregroundStyle(Color(hex: linked.color))
                Text(linked.name)
                    .font(PortlyTypography.bodyMedium)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
                if let health = linked.health {
                    Circle()
                        .fill(health.color)
                        .frame(width: 6, height: 6)
                        .help(health.label)
                        .accessibilityLabel(health.label)
                }
                HStack(spacing: 4) {
                    Text("\(open)")
                        .font(PortlyTypography.metric)
                        .foregroundStyle(open > 0 ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.6))
                        .monospacedDigit()
                        .help("\(open) open issue\(open == 1 ? "" : "s")")
                    if urgent > 0 {
                        HStack(spacing: 2) {
                            TalvoPriorityGlyph(priority: .urgent, size: 10)
                            Text("\(urgent)")
                                .font(PortlyTypography.label)
                                .foregroundStyle(.orange)
                                .monospacedDigit()
                        }
                        .help("\(urgent) urgent")
                    }
                }
                if workspace.talvoPanelProjectID == project.id {
                    NucleoIconView(.chevronDown, size: 9)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(180))
                }
                connectionDot
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 6) {
                NucleoIconView(.talvo, size: 14)
                    .foregroundStyle(.secondary)
                Text("Link to Talvo")
                    .font(PortlyTypography.body)
                    .foregroundStyle(.secondary)
                connectionDot
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
    }

    /// A quiet mark when the stream is not live: Talvo may be behind.
    @ViewBuilder
    private var connectionDot: some View {
        switch center.connection {
        case .live, .off:
            EmptyView()
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
                .accessibilityLabel("Connecting to Talvo")
        case .offline:
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
                .help("Talvo is unreachable right now; Portly keeps trying.")
        case .refused:
            NucleoIconView(.warning, size: 10)
                .foregroundStyle(.orange)
                .help("Talvo refused the token. Check Settings → Talvo.")
        }
    }

    private var helpText: String {
        if let linked {
            return workspace.talvoPanelProjectID == project.id
                ? "Close the Talvo view of \(linked.name)"
                : "Open \(linked.name) in Talvo: issues, milestones, documents"
        }
        return "Link \(project.name) to one of your Talvo projects"
    }
}

/// The Talvo projects the token can see, to pick the one this Portly project
/// mirrors. Searchable, live ones first.
struct TalvoLinkPicker: View {
    let project: Project

    @ObservedObject private var center = TalvoCenter.shared
    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var query = ""

    private var matches: [TalvoProject] {
        let needle = TalvoSearch.fold(query)
        let all = center.data.orderedProjects
        guard !needle.isEmpty else { return all }
        return all.filter { TalvoSearch.fold($0.name).contains(needle) || TalvoSearch.fold($0.slug).contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                NucleoIconView(.talvo, size: 14)
                    .foregroundStyle(Color.accentColor)
                Text("Link \(project.name) to a Talvo project")
                    .font(PortlyTypography.bodyMedium)
            }
            TextField("Search projects", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            if center.data.projects.isEmpty {
                Text(center.connection == .connecting ? "Loading your Talvo projects…" : "No Talvo project is visible to this token.")
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .frame(height: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { talvoProject in
                            Button {
                                workspace.linkTalvoProject(talvoProject.id, to: project.id)
                                ToolbarPopover.dismiss()
                                workspace.toggleTalvoPanel(projectID: project.id)
                            } label: {
                                HStack(spacing: 9) {
                                    NucleoIconView(TalvoIcons.glyph(for: talvoProject.icon, fallback: .talvo), size: 13)
                                        .foregroundStyle(Color(hex: talvoProject.color))
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(talvoProject.name)
                                            .font(PortlyTypography.body)
                                            .lineLimit(1)
                                        if let summary = talvoProject.summary, !summary.isEmpty {
                                            Text(summary)
                                                .font(PortlyTypography.metadata)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    TalvoChip(text: talvoProject.status.label, color: talvoProject.status.color)
                                    let open = center.data.openIssueCount(inProject: talvoProject.id)
                                    Text("\(open)")
                                        .font(PortlyTypography.metadata)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                        .frame(minWidth: 20, alignment: .trailing)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: min(CGFloat(max(matches.count, 1)) * 36, 300))
            }
            Text("The link is kept in Portly's own files; nothing is written to Talvo.")
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 380)
    }
}
