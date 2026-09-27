import Foundation
import PortlyCore

/// Which projects the sidebar lists, in what order, and which wait in the
/// archive behind the button beside the search field.
///
/// Archiving is explicit state rather than something recomputed from dates at
/// every launch: a project goes to the archive when you put it there, or when
/// it has been idle for the configured number of days, and it stays there until
/// you bring it back or one of its servers starts.
enum SidebarVisibility {
    /// Should an idle project archive itself? Never while it is in use: a
    /// server running, an agent working, or simply the project on screen.
    static func shouldAutoArchive(
        lastActivity: Date?,
        hasRunningServer: Bool,
        isWorking: Bool,
        isSelected: Bool,
        afterDays days: Int,
        now: Date = Date()
    ) -> Bool {
        guard days > 0, !hasRunningServer, !isWorking, !isSelected else { return false }
        guard let lastActivity else { return true }
        return now.timeIntervalSince(lastActivity) >= TimeInterval(days) * 24 * 60 * 60
    }

    /// Projects in sidebar order: the stored order first, then anything it
    /// does not know yet in configuration order.
    static func ordered(_ projects: [Project], order: [String]) -> [Project] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return projects.enumerated()
            .sorted { lhs, rhs in
                switch (rank[lhs.element.id], rank[rhs.element.id]) {
                case let (left?, right?): return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// The order with `id` in front, every known project kept.
    static func movingToTop(_ id: String, in order: [String], projects: [Project]) -> [String] {
        let full = complete(order, projects: projects)
        return [id] + full.filter { $0 != id }
    }

    /// The order with `id` moved to where `target` is, the way a dragged row
    /// takes the place of the one it passes over: after it when coming from
    /// above, before it when coming from below.
    static func moving(_ id: String, onto target: String, in order: [String], projects: [Project]) -> [String] {
        var full = complete(order, projects: projects)
        guard id != target,
              let from = full.firstIndex(of: id),
              let to = full.firstIndex(of: target) else { return full }
        full.remove(at: from)
        full.insert(id, at: to)
        return full
    }

    /// One step up or down among the given visible projects, skipping the
    /// archived ones in between.
    static func moving(_ id: String, by offset: Int, among visible: [String], in order: [String], projects: [Project]) -> [String] {
        guard let index = visible.firstIndex(of: id) else { return complete(order, projects: projects) }
        let targetIndex = index + offset
        guard visible.indices.contains(targetIndex) else { return complete(order, projects: projects) }
        return moving(id, onto: visible[targetIndex], in: order, projects: projects)
    }

    /// Every configured project exactly once, in sidebar order, dropping ids
    /// of projects that no longer exist.
    static func complete(_ order: [String], projects: [Project]) -> [String] {
        ordered(projects, order: order).map(\.id)
    }

    /// Projects for the archive list: name matches first by position of the
    /// match, then most recently used.
    static func search(
        _ projects: [Project],
        query: String,
        lastActivity: (String) -> Date?
    ) -> [Project] {
        let needle = fold(query)
        let ranked = projects.compactMap { project -> (project: Project, rank: Int)? in
            guard !needle.isEmpty else { return (project, 0) }
            let name = fold(project.name)
            if name.hasPrefix(needle) { return (project, 0) }
            if name.contains(needle) { return (project, 1) }
            if fold(project.root).contains(needle) { return (project, 2) }
            return nil
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                let left = lastActivity(lhs.project.id) ?? .distantPast
                let right = lastActivity(rhs.project.id) ?? .distantPast
                if left != right { return left > right }
                return lhs.project.name.localizedCaseInsensitiveCompare(rhs.project.name) == .orderedAscending
            }
            .map(\.project)
    }

    /// Case and accents do not matter when looking for a project by name.
    static func fold(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
    }
}
