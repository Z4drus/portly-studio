import Foundation

/// Everything Portly knows of the Talvo workspace: the light records of the
/// bootstrap, kept up to date by deltas, indexed by id. Pure data, so the
/// merging rules can be checked without a server.
struct TalvoWorkspaceData: Codable, Equatable {
    /// The journal sequence this data is current to; 0 means never loaded.
    var seq = 0
    var issuePrefix = "BLE"
    var me: TalvoUser?
    var users: [String: TalvoUser] = [:]
    var statuses: [String: TalvoStatus] = [:]
    var labels: [String: TalvoLabel] = [:]
    var projects: [String: TalvoProject] = [:]
    var members: [TalvoProjectMember] = []
    var milestones: [String: TalvoMilestone] = [:]
    var projectLinks: [String: TalvoProjectLink] = [:]
    var issues: [String: TalvoIssue] = [:]
    var relations: [String: TalvoRelation] = [:]
    var documents: [String: TalvoDocument] = [:]

    var isLoaded: Bool { seq > 0 }

    /// Replace everything with a fresh bootstrap.
    mutating func apply(_ bootstrap: TalvoBootstrap) {
        seq = bootstrap.seq
        issuePrefix = bootstrap.settings.issuePrefix
        me = bootstrap.me
        users = Dictionary(bootstrap.users.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        statuses = Dictionary(bootstrap.statuses.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        labels = Dictionary(bootstrap.labels.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        projects = Dictionary(bootstrap.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        members = bootstrap.projectMembers
        milestones = Dictionary(bootstrap.milestones.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        projectLinks = Dictionary(bootstrap.projectLinks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        issues = Dictionary(bootstrap.issues.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        relations = Dictionary(bootstrap.relations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        documents = Dictionary(bootstrap.documents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Merge a delta: changed rows replace theirs, deleted ids go, and the
    /// members of a touched project are replaced wholesale, as Talvo sends
    /// them all again.
    mutating func apply(_ delta: TalvoSyncDelta) {
        precondition(!delta.reset, "a reset delta carries nothing to merge")
        seq = max(seq, delta.seq)
        for user in delta.users { users[user.id] = user }
        for label in delta.labels { labels[label.id] = label }
        if !delta.statuses.isEmpty {
            statuses = Dictionary(delta.statuses.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        for project in delta.projects { projects[project.id] = project }
        for milestone in delta.milestones { milestones[milestone.id] = milestone }
        for link in delta.projectLinks { projectLinks[link.id] = link }
        for issue in delta.issues { issues[issue.id] = issue }
        for relation in delta.relations { relations[relation.id] = relation }
        for document in delta.documents { documents[document.id] = document }
        let touchedProjects = Set(delta.touched.projects)
        if !touchedProjects.isEmpty {
            members.removeAll { touchedProjects.contains($0.projectId) }
            members.append(contentsOf: delta.projectMembers.filter { touchedProjects.contains($0.projectId) })
        }
        for (entity, ids) in delta.deleted {
            for id in ids {
                switch entity {
                case "user": users.removeValue(forKey: id)
                case "label": labels.removeValue(forKey: id)
                case "project":
                    projects.removeValue(forKey: id)
                    members.removeAll { $0.projectId == id }
                case "milestone": milestones.removeValue(forKey: id)
                case "projectLink": projectLinks.removeValue(forKey: id)
                case "issue": issues.removeValue(forKey: id)
                case "relation": relations.removeValue(forKey: id)
                case "document": documents.removeValue(forKey: id)
                default: break
                }
            }
        }
    }

    // MARK: Lookups

    func identifier(for issue: TalvoIssue) -> String { issue.identifier(prefix: issuePrefix) }

    /// `BLE-12`, `ble-12` or `12` to the issue's id, when it is known.
    static func issueID(forIdentifier text: String, in data: TalvoWorkspaceData) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.split(separator: "-").last.map(String.init) ?? trimmed
        guard let number = Int(digits) else { return nil }
        if trimmed.contains("-"), !trimmed.lowercased().hasPrefix(data.issuePrefix.lowercased() + "-") { return nil }
        return data.issues.values.first { $0.number == number }?.id
    }

    func issues(inProject projectID: String) -> [TalvoIssue] {
        issues.values.filter { $0.projectId == projectID && $0.archivedAt == nil }
    }

    func milestones(inProject projectID: String) -> [TalvoMilestone] {
        milestones.values.filter { $0.projectId == projectID }.sorted { $0.position < $1.position }
    }

    func links(inProject projectID: String) -> [TalvoProjectLink] {
        projectLinks.values.filter { $0.projectId == projectID }.sorted { $0.position < $1.position }
    }

    func documents(inProject projectID: String) -> [TalvoDocument] {
        documents.values.filter { $0.projectId == projectID && $0.archivedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func memberIDs(ofProject projectID: String) -> [String] {
        members.filter { $0.projectId == projectID }.map(\.userId)
    }

    var orderedStatuses: [TalvoStatus] {
        statuses.values.sorted { $0.position < $1.position }
    }

    /// Projects a person can link to, live ones first, in Talvo's order.
    var orderedProjects: [TalvoProject] {
        projects.values
            .filter { $0.archivedAt == nil }
            .sorted { lhs, rhs in
                let left = lhs.status == .completed || lhs.status == .canceled
                let right = rhs.status == .completed || rhs.status == .canceled
                if left != right { return !left }
                return lhs.position < rhs.position
            }
    }

    /// Where a project stands, counted from its issues and their statuses.
    func progress(ofProject projectID: String) -> TalvoProgress {
        progress(of: issues(inProject: projectID))
    }

    func progress(of issues: [TalvoIssue]) -> TalvoProgress {
        var completed = 0
        var started = 0
        var canceled = 0
        for issue in issues {
            switch statuses[issue.statusId]?.type {
            case .completed?: completed += 1
            case .started?: started += 1
            case .canceled?: canceled += 1
            default: break
            }
        }
        let counted = issues.count - canceled
        return TalvoProgress(
            total: issues.count,
            completed: completed,
            started: started,
            canceled: canceled,
            ratio: counted > 0 ? Double(completed) / Double(counted) : 0
        )
    }

    /// Issues still open in a project: anything not completed or canceled.
    func openIssueCount(inProject projectID: String) -> Int {
        issues(inProject: projectID).filter { statuses[$0.statusId]?.type.isOpen ?? true }.count
    }

    func urgentOpenIssueCount(inProject projectID: String) -> Int {
        issues(inProject: projectID).filter { $0.priority == .urgent && (statuses[$0.statusId]?.type.isOpen ?? true) }.count
    }
}
