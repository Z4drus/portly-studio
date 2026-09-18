import Foundation
import PortlyCore

/// Which projects the sidebar lists, and which wait in the older-projects list.
///
/// A project earns its place by being in use: a server running, or something
/// done in it during the last day. Everything else stays one click away behind
/// the button next to the search field, so a long history of projects does not
/// bury the three being worked on this week.
enum SidebarVisibility {
    /// How long a project stays listed after it was last worked on.
    static let recencyWindow: TimeInterval = 24 * 60 * 60

    static func isVisible(
        hasRunningServer: Bool,
        lastActivity: Date?,
        isSelected: Bool,
        now: Date = Date()
    ) -> Bool {
        // The project on screen never disappears from under the user.
        if hasRunningServer || isSelected { return true }
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) < recencyWindow
    }

    /// Projects for the older-projects list: name matches first by position of
    /// the match, then most recently used.
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
