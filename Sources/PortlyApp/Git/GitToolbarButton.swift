import AppKit
import SwiftUI

// MARK: - Toolbar button

/// The Git readout in the toolbar, left of the mug: the branch glyph, the
/// lines added and removed since the last commit, and how many commits wait
/// to be pushed. Shown on every project screen whose folder is a repository.
/// Clicking opens the popover with the files, the history and the one action
/// that matters here: asking the agent to commit and push.
struct GitToolbarButton: View {
    let projectRoot: String

    @ObservedObject private var monitor: GitRepositoryMonitor

    init(projectRoot: String) {
        self.projectRoot = projectRoot
        _monitor = ObservedObject(wrappedValue: GitCenter.shared.monitor(forRoot: projectRoot))
    }

    private var summary: GitSnapshot.Summary {
        monitor.snapshot?.summary ?? GitSnapshot.Summary(linesAdded: 0, linesRemoved: 0, ahead: 0, fileCount: 0, hasConflicts: false)
    }

    var body: some View {
        Button {
            let monitor = self.monitor
            monitor.refreshNow()
            ToolbarPopover.toggle(id: "git") {
                GitPopoverView(monitor: monitor)
            }
        } label: {
            pill
        }
        .help(helpText)
        .accessibilityLabel("Git")
        .accessibilityValue(accessibilityValue)
        .onAppear { monitor.activate() }
        .onDisappear { monitor.deactivate() }
    }

    private var pill: some View {
        HStack(spacing: 7) {
            NucleoIconView(.gitBranch, size: 14)
                .foregroundStyle(summary.hasConflicts ? Color.orange : Color.secondary)

            HStack(spacing: 6) {
                Text("+\(summary.linesAdded)")
                    .foregroundStyle(summary.linesAdded > 0 ? Color.green : Color.secondary.opacity(0.55))
                Text("−\(summary.linesRemoved)")
                    .foregroundStyle(summary.linesRemoved > 0 ? Color.red : Color.secondary.opacity(0.55))
            }
            .font(PortlyTypography.metric)
            .monospacedDigit()

            if summary.ahead > 0 {
                HStack(spacing: 2) {
                    NucleoIconView(.arrowUp, size: 9)
                    Text("\(summary.ahead)")
                        .font(PortlyTypography.label)
                        .monospacedDigit()
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 2)
        .frame(minWidth: 86, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var helpText: String {
        guard let snapshot = monitor.snapshot else { return "Git: reading the repository…" }
        var parts: [String] = []
        if let branch = snapshot.branch { parts.append("On \(branch)") }
        parts.append(snapshot.isClean
            ? "working tree clean"
            : "\(snapshot.files.count) changed file\(snapshot.files.count == 1 ? "" : "s"), +\(snapshot.linesAdded) −\(snapshot.linesRemoved)")
        if snapshot.ahead > 0 { parts.append("\(snapshot.ahead) commit\(snapshot.ahead == 1 ? "" : "s") to push") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        "\(summary.linesAdded) lines added, \(summary.linesRemoved) removed, \(summary.ahead) commits to push"
    }
}

// MARK: - Popover

/// What is going on in the repository, at a glance: branch and upstream, the
/// changed files with their line counts, the ignored environment files, and
/// recent history drawn as a graph. One button at the bottom hands the
/// commit-and-push request to the agent; Git itself is never driven from here.
struct GitPopoverView: View {
    @ObservedObject var monitor: GitRepositoryMonitor
    @ObservedObject private var workspace = StudioWorkspace.shared

    private static let width: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            if let snapshot = monitor.snapshot {
                changes(snapshot)
                Divider()
                history(snapshot)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the repository…")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .animation(Motion.state, value: monitor.snapshot?.summary)
    }

    // MARK: Header

    private var header: some View {
        let snapshot = monitor.snapshot
        return HStack(spacing: 10) {
            NucleoIconView(.gitBranch, size: 15)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snapshot?.branch ?? (snapshot == nil ? "Git" : "Detached HEAD"))
                        .font(PortlyTypography.bodyMedium)
                        .lineLimit(1)
                    if let snapshot, snapshot.ahead > 0 || snapshot.behind > 0 {
                        aheadBehind(snapshot)
                    }
                }
                Text(subtitle(snapshot))
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity)
                    .accessibilityLabel("Refreshing")
            }
            if let url = snapshot?.remoteWebURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    NucleoIconView(.externalLink, size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(url.host ?? "the remote") in the browser")
                .accessibilityLabel("Open the remote repository")
            }
        }
    }

    private func aheadBehind(_ snapshot: GitSnapshot) -> some View {
        HStack(spacing: 6) {
            if snapshot.ahead > 0 {
                HStack(spacing: 2) {
                    NucleoIconView(.arrowUp, size: 9)
                    Text("\(snapshot.ahead)")
                }
                .foregroundStyle(Color.accentColor)
                .help("\(snapshot.ahead) commit\(snapshot.ahead == 1 ? "" : "s") to push")
            }
            if snapshot.behind > 0 {
                HStack(spacing: 2) {
                    NucleoIconView(.arrowDown, size: 9)
                    Text("\(snapshot.behind)")
                }
                .foregroundStyle(.secondary)
                .help("\(snapshot.behind) commit\(snapshot.behind == 1 ? "" : "s") on the remote not pulled yet")
            }
        }
        .font(PortlyTypography.label)
        .monospacedDigit()
    }

    private func subtitle(_ snapshot: GitSnapshot?) -> String {
        guard let snapshot else { return monitor.projectRoot.abbreviatingTilde }
        var parts: [String] = []
        if let upstream = snapshot.upstream {
            parts.append(snapshot.ahead == 0 && snapshot.behind == 0 ? "in sync with \(upstream)" : "tracks \(upstream)")
        } else if snapshot.isInitial {
            parts.append("no commit yet")
        } else {
            parts.append("no upstream")
        }
        if let root = monitor.repositoryRoot, root != monitor.projectRoot {
            parts.append(root.abbreviatingTilde)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Changes

    private static let changeRowHeight: CGFloat = 26
    private static let visibleChangeRows = 7

    private func changes(_ snapshot: GitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(
                "Changes",
                icon: .gitCompare,
                detail: snapshot.isClean
                    ? "nothing to commit"
                    : "\(snapshot.files.count) file\(snapshot.files.count == 1 ? "" : "s") · +\(snapshot.linesAdded) −\(snapshot.linesRemoved)"
            )
            if snapshot.isClean, snapshot.ignoredEnvFiles.isEmpty {
                HStack(spacing: 8) {
                    NucleoIconView(.checkCircle, size: 13)
                        .foregroundStyle(.green)
                    Text("Working tree clean")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }
                .frame(height: Self.changeRowHeight)
            } else {
                let rows = snapshot.files.count + snapshot.ignoredEnvFiles.count
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.files) { file in
                            GitChangeRow(file: file)
                        }
                        ForEach(snapshot.ignoredEnvFiles, id: \.self) { name in
                            ignoredRow(name)
                        }
                    }
                }
                .frame(height: CGFloat(min(rows, Self.visibleChangeRows)) * Self.changeRowHeight)
                .scrollIndicators(rows > Self.visibleChangeRows ? .automatic : .hidden)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// An environment file Git ignores: present here, never committed, never
    /// pushed. Greyed so it reads as "not part of the repository".
    private func ignoredRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            NucleoIconView(.eyeSlash, size: 11)
                .foregroundStyle(.quaternary)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Text("ignored")
                .font(PortlyTypography.label)
                .foregroundStyle(.quaternary)
        }
        .frame(height: Self.changeRowHeight)
        .help("\(name) is in .gitignore: it stays on this Mac and is never committed or pushed")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), ignored by Git")
    }

    // MARK: History

    private static let visibleHistoryRows = 9

    private func history(_ snapshot: GitSnapshot) -> some View {
        let toPush = snapshot.commits.filter(\.isLocalOnly).count
        let layout = GitGraph.layout(snapshot.commits)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(
                "History",
                icon: .gitCommit,
                detail: snapshot.commits.isEmpty
                    ? (snapshot.isInitial ? "no commit yet" : "")
                    : toPush > 0 ? "\(toPush) not pushed" : "all pushed"
            )
            if snapshot.commits.isEmpty {
                Text(snapshot.isInitial ? "The first commit will appear here." : "No history to show.")
                    .font(PortlyTypography.body)
                    .foregroundStyle(.secondary)
                    .frame(height: GitGraphView.rowHeight)
            } else {
                ScrollView(.vertical) {
                    GitGraphView(layout: layout)
                }
                .frame(height: CGFloat(min(layout.rows.count, Self.visibleHistoryRows)) * GitGraphView.rowHeight)
                .scrollIndicators(layout.rows.count > Self.visibleHistoryRows ? .automatic : .hidden)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Footer

    /// Whether a terminal can receive the request right now.
    private var canTellAgent: Bool { workspace.canInsertIntoFocusedTerminal }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(canTellAgent
                ? "Typed into the focused terminal, you press Return."
                : "Open a coding session to hand this to an agent.")
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                ToolbarPopover.dismiss()
                workspace.insertIntoFocusedTerminal(GitAgentMessages.commitAndPush)
            } label: {
                NucleoLabel("Tell the agent: commit & push", icon: .paperPlane, size: 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canTellAgent)
            .help(GitAgentMessages.commitAndPush)
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String, icon: AppIcon, detail: String) -> some View {
        HStack(spacing: 6) {
            NucleoIconView(icon, size: 11)
                .foregroundStyle(.tertiary)
            Text(title.uppercased())
                .font(PortlyTypography.label)
                .foregroundStyle(.tertiary)
                .kerning(0.6)
            Spacer()
            Text(detail)
                .font(PortlyTypography.metadata)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

/// One changed file: its status mark, its name with the folder it sits in,
/// and the lines it adds and removes.
private struct GitChangeRow: View {
    let file: GitFileChange

    var body: some View {
        HStack(spacing: 8) {
            Text(file.kind.mark)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help(file.kind.label)

            HStack(spacing: 5) {
                Text(file.fileName)
                    .font(PortlyTypography.body)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let directory = file.directory {
                    Text(directory)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if file.staged {
                Circle()
                    .fill(Color.accentColor.opacity(file.unstaged ? 0.45 : 1))
                    .frame(width: 5, height: 5)
                    .help(file.unstaged ? "Partly staged" : "Staged")
                    .accessibilityLabel(file.unstaged ? "Partly staged" : "Staged")
            }

            if file.isBinary {
                Text("binary")
                    .font(PortlyTypography.label)
                    .foregroundStyle(.quaternary)
            } else {
                HStack(spacing: 5) {
                    Text("+\(file.linesAdded)")
                        .foregroundStyle(file.linesAdded > 0 ? Color.green : Color.secondary.opacity(0.4))
                    Text("−\(file.linesRemoved)")
                        .foregroundStyle(file.linesRemoved > 0 ? Color.red : Color.secondary.opacity(0.4))
                }
                .font(PortlyTypography.metadata)
                .monospacedDigit()
            }
        }
        .frame(height: 26)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.kind.label) \(file.path), \(file.linesAdded) added, \(file.linesRemoved) removed")
    }

    private var tooltip: String {
        var text = "\(file.kind.label): \(file.path)"
        if let previous = file.previousPath { text += "\nwas \(previous)" }
        return text
    }

    private var color: Color {
        switch file.kind {
        case .modified, .typeChanged: return .orange
        case .added, .untracked, .copied: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .conflicted: return .red
        }
    }
}

private extension String {
    var abbreviatingTilde: String { NSString(string: self).abbreviatingWithTildeInPath }
}
