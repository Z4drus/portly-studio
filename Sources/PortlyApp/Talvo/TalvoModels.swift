import Foundation
import SwiftUI

// MARK: - Talvo records
//
// Mirrors of `vps/bleeze-tools/src/talvo/types.ts` in the dashboard
// repository: the JSON Talvo sends is decoded as is, camelCase keys included.
// Dates travel as ISO 8601 strings and are parsed when a view needs them.

/// A person admitted in Talvo (a dashboard account).
struct TalvoUser: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var email: String
    var role: String
    var initials: String
    var color: String
    var active: Bool
    var lastSeenAt: String?

    var isAdmin: Bool { role == "admin" }
}

/// The lifecycle class of an issue status, the same five as Linear.
enum TalvoStatusType: String, Codable, Hashable {
    case backlog
    case unstarted
    case started
    case completed
    case canceled

    /// Unknown future types decode as backlog rather than failing the whole payload.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TalvoStatusType(rawValue: raw) ?? .backlog
    }

    /// Statuses that still count as open work.
    var isOpen: Bool { self == .backlog || self == .unstarted || self == .started }
}

struct TalvoStatus: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var type: TalvoStatusType
    var color: String
    var position: Double
    var isDefault: Bool
}

struct TalvoLabel: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var color: String
    var description: String?
    var position: Double
    var archivedAt: String?
}

/// Issue and project priority, Linear's values: 0 none, 1 urgent … 4 low.
enum TalvoPriority: Int, Codable, Hashable, CaseIterable, Comparable {
    case none = 0
    case urgent = 1
    case high = 2
    case medium = 3
    case low = 4

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = TalvoPriority(rawValue: raw) ?? .none
    }

    var label: String {
        switch self {
        case .none: return "No priority"
        case .urgent: return "Urgent"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Urgent first, no priority last: the order a list wants.
    var sortRank: Int { self == .none ? 5 : rawValue }

    static func < (lhs: TalvoPriority, rhs: TalvoPriority) -> Bool { lhs.sortRank < rhs.sortRank }
}

enum TalvoProjectStatus: String, Codable, Hashable {
    case backlog
    case planned
    case started
    case paused
    case completed
    case canceled

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TalvoProjectStatus(rawValue: raw) ?? .backlog
    }

    var label: String {
        switch self {
        case .backlog: return "Backlog"
        case .planned: return "Planned"
        case .started: return "In progress"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .canceled: return "Canceled"
        }
    }

    var color: Color {
        switch self {
        case .backlog: return .secondary
        case .planned: return .blue
        case .started: return .orange
        case .paused: return .yellow
        case .completed: return .green
        case .canceled: return .secondary
        }
    }
}

enum TalvoHealth: String, Codable, Hashable {
    case onTrack
    case atRisk
    case offTrack

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TalvoHealth(rawValue: raw) ?? .onTrack
    }

    var label: String {
        switch self {
        case .onTrack: return "On track"
        case .atRisk: return "At risk"
        case .offTrack: return "Off track"
        }
    }

    var color: Color {
        switch self {
        case .onTrack: return .green
        case .atRisk: return .orange
        case .offTrack: return .red
        }
    }
}

struct TalvoProject: Codable, Hashable, Identifiable {
    var id: String
    var slug: String
    var name: String
    var summary: String?
    var icon: String?
    var color: String
    var status: TalvoProjectStatus
    var health: TalvoHealth?
    var healthUpdatedAt: String?
    var priority: TalvoPriority
    var leadId: String?
    var startDate: String?
    var targetDate: String?
    var visibility: String
    var position: Double
    var archivedAt: String?
    var createdAt: String
    var updatedAt: String
}

struct TalvoProjectMember: Codable, Hashable {
    var projectId: String
    var userId: String
}

struct TalvoMilestone: Codable, Hashable, Identifiable {
    var id: String
    var projectId: String
    var name: String
    var description: String?
    var targetDate: String?
    var position: Double
    /// Only present in a project's detail read.
    var progress: TalvoProgress?
}

struct TalvoProjectLink: Codable, Hashable, Identifiable {
    var id: String
    var projectId: String
    var title: String
    var url: String
    var kind: String
    var position: Double
}

struct TalvoProjectUpdate: Codable, Hashable, Identifiable {
    var id: String
    var projectId: String
    var health: TalvoHealth
    var body: String
    var authorName: String
    var createdAt: String
}

/// An issue as lists know it: everything but the long text.
struct TalvoIssue: Codable, Hashable, Identifiable {
    var id: String
    var number: Int
    var title: String
    var statusId: String
    var priority: TalvoPriority
    var projectId: String?
    var milestoneId: String?
    var assigneeId: String?
    var creatorId: String?
    var parentId: String?
    var estimate: Double?
    var dueDate: String?
    var position: Double
    var labelIds: [String]
    var archivedAt: String?
    var createdAt: String
    var updatedAt: String
    var completedAt: String?

    func identifier(prefix: String) -> String { "\(prefix)-\(number)" }
}

struct TalvoRelation: Codable, Hashable, Identifiable {
    var id: String
    var issueId: String
    var relatedId: String
    var type: String
}

struct TalvoIssueLink: Codable, Hashable, Identifiable {
    var id: String
    var issueId: String
    var title: String
    var url: String
}

struct TalvoComment: Codable, Hashable, Identifiable {
    var id: String
    var issueId: String
    var parentId: String?
    var authorId: String?
    var authorName: String
    var body: String
    var createdAt: String
    var updatedAt: String
}

struct TalvoDocument: Codable, Hashable, Identifiable {
    var id: String
    var projectId: String?
    var title: String
    var icon: String?
    var color: String?
    var authorId: String?
    var archivedAt: String?
    var createdAt: String
    var updatedAt: String
}

/// One change, `data` being a small JSON object (`{from, to}` mostly).
struct TalvoActivity: Codable, Hashable, Identifiable {
    var id: String
    var entityType: String
    var entityId: String
    var projectId: String?
    var actorId: String?
    var actorName: String
    var via: String?
    var kind: String
    var data: TalvoJSON
    var createdAt: String
}

/// Progress over a set of issues, as Talvo computes it.
struct TalvoProgress: Codable, Hashable {
    var total: Int
    var completed: Int
    var started: Int
    var canceled: Int
    var ratio: Double
}

/// A reference to another issue, as the detail read names parents and children.
struct TalvoIssueReference: Codable, Hashable, Identifiable {
    var id: String
    var identifier: String
    var title: String
}

/// Everything about one issue, read on demand.
struct TalvoIssueDetail: Codable, Hashable {
    var id: String
    var identifier: String
    var number: Int
    var title: String
    var description: String
    var statusId: String
    var priority: TalvoPriority
    var projectId: String?
    var milestoneId: String?
    var assigneeId: String?
    var creatorId: String?
    var parentId: String?
    var parent: TalvoIssueReference?
    var estimate: Double?
    var dueDate: String?
    var labelIds: [String]
    var archivedAt: String?
    var createdAt: String
    var updatedAt: String
    var children: [TalvoIssue]
    var relations: [TalvoRelation]
    var links: [TalvoIssueLink]
    var comments: [TalvoComment]
    var activity: [TalvoActivity]
}

/// Everything about one project, read on demand.
struct TalvoProjectDetail: Codable, Hashable {
    var id: String
    var slug: String
    var name: String
    var summary: String?
    var description: String
    var icon: String?
    var color: String
    var status: TalvoProjectStatus
    var health: TalvoHealth?
    var priority: TalvoPriority
    var leadId: String?
    var startDate: String?
    var targetDate: String?
    var memberIds: [String]
    var milestones: [TalvoMilestone]
    var links: [TalvoProjectLink]
    var updates: [TalvoProjectUpdate]
    var activity: [TalvoActivity]
    var progress: TalvoProgress
    var issueCountsByStatus: [String: Int]
    var documents: [TalvoDocument]
}

struct TalvoDocumentDetail: Codable, Hashable {
    var id: String
    var projectId: String?
    var title: String
    var icon: String?
    var color: String?
    var content: String
    var updatedAt: String
}

/// `GET /api/portly/me`: who the token belongs to and what it may do.
struct TalvoIdentity: Codable, Hashable {
    struct Token: Codable, Hashable {
        var id: String
        var name: String
        var prefix: String
    }

    var user: TalvoUser
    var scopes: [String]
    var token: Token
    var issuePrefix: String
    var publicUrl: String?

    var canWrite: Bool { scopes.contains("write") }
}

/// `GET /api/portly/bootstrap`: the whole visible workspace, without long texts.
struct TalvoBootstrap: Codable {
    struct Settings: Codable { var issuePrefix: String }

    var seq: Int
    var me: TalvoUser
    var settings: Settings
    var users: [TalvoUser]
    var statuses: [TalvoStatus]
    var labels: [TalvoLabel]
    var projects: [TalvoProject]
    var projectMembers: [TalvoProjectMember]
    var milestones: [TalvoMilestone]
    var projectLinks: [TalvoProjectLink]
    var issues: [TalvoIssue]
    var relations: [TalvoRelation]
    var documents: [TalvoDocument]
}

/// `GET /api/portly/sync?since=`: what changed since a sequence number.
struct TalvoSyncDelta: Codable {
    struct Touched: Codable {
        var issues: [String]
        var projects: [String]
        var documents: [String]
    }

    var seq: Int
    var reset: Bool
    var users: [TalvoUser]
    var labels: [TalvoLabel]
    var statuses: [TalvoStatus]
    var projects: [TalvoProject]
    var projectMembers: [TalvoProjectMember]
    var milestones: [TalvoMilestone]
    var projectLinks: [TalvoProjectLink]
    var issues: [TalvoIssue]
    var relations: [TalvoRelation]
    var documents: [TalvoDocument]
    var touched: Touched
    var deleted: [String: [String]]
}

// MARK: - Loose JSON

/// A JSON value kept as data: activity payloads differ per kind.
enum TalvoJSON: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([TalvoJSON])
    case object([String: TalvoJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TalvoJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TalvoJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> TalvoJSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    /// The value shown to a person: strings as they are, numbers without a
    /// pointless fraction, nothing for null.
    var displayText: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "yes" : "no"
        case .null: return nil
        case .array(let values): return values.compactMap(\.displayText).joined(separator: ", ")
        case .object: return nil
        }
    }
}

// MARK: - Dates

/// Talvo writes ISO 8601 with milliseconds (`2026-10-25T09:12:03.123Z`) and
/// plain days (`2026-11-30`) for targets and due dates.
enum TalvoDates {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text) ?? day.date(from: text)
    }

    /// "30 Nov" for a day, with the year once it is not this one.
    static func shortDay(_ text: String?) -> String? {
        guard let date = parse(text) else { return nil }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func isPast(_ text: String?) -> Bool {
        guard let date = parse(text) else { return false }
        return date < Calendar.current.startOfDay(for: Date())
    }
}
