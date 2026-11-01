import AppKit
import Foundation
import SQLite3

/// Reads the Things 3 database, read-only.
///
/// Things has no API. Its data sits in a SQLite file that Things Cloud keeps in
/// sync with the phone; reading it is safe, writing it is not: Things would not
/// notice, and the sync could lose the change or worse. Every change goes
/// through Things itself, with `ThingsLinks`.
enum ThingsDatabase {
    struct Snapshot: Equatable {
        var areas: [ThingsArea]
        /// The followed area, once one is chosen or found.
        var area: ThingsArea?
        var tasks: [ThingsTask]
        /// Things' URL token. Missing until "Enable Things URLs" is turned
        /// on in Things → Settings → General; without it no to-do can be edited.
        var urlToken: String?
    }

    /// Where Things keeps its data: `ThingsData-<id>` changes per install.
    static func locate(fileManager: FileManager = .default) -> URL? {
        let container = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: container.path) else { return nil }
        return entries
            .filter { $0.hasPrefix("ThingsData-") }
            .sorted()
            .map {
                container
                    .appendingPathComponent($0, isDirectory: true)
                    .appendingPathComponent("Things Database.thingsdatabase/main.sqlite")
            }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// The area to follow: the one picked, else one named "Projets", else the first.
    static func preferredArea(in areas: [ThingsArea], picked: String?) -> ThingsArea? {
        if let picked, let area = areas.first(where: { $0.id == picked }) { return area }
        let names = ["projets", "projet", "projects", "project"]
        return areas.first { names.contains($0.title.lowercased()) } ?? areas.first
    }

    static func read(at url: URL, pickedAreaID: String?) throws -> Snapshot {
        let connection = try Connection(url: url)
        let areas = try connection.rows("SELECT uuid, title FROM TMArea ORDER BY \"index\"") { statement in
            ThingsArea(id: statement.text(0) ?? "", title: statement.text(1) ?? "")
        }
        let area = preferredArea(in: areas, picked: pickedAreaID)
        let tasks = try area.map { try openTasks(in: $0.id, connection: connection) } ?? []
        let token = try connection.rows("SELECT uriSchemeAuthenticationToken FROM TMSettings LIMIT 1") { $0.text(0) }
            .compactMap { $0 }
            .first { !$0.isEmpty }
        return Snapshot(areas: areas, area: area, tasks: tasks, urlToken: token)
    }

    /// The to-dos of `ids` that Things no longer lists as open: completed,
    /// canceled, trashed or deleted.
    static func closedTasks(among ids: Set<String>, at url: URL) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let connection = try Connection(url: url)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let ordered = Array(ids)
        let open = try connection.rows(
            "SELECT uuid FROM TMTask WHERE uuid IN (\(placeholders)) AND status = 0 AND trashed = 0",
            bind: ordered
        ) { $0.text(0) ?? "" }
        return ids.subtracting(open)
    }

    /// Open to-dos directly in the area, then those of its open projects
    /// (under a heading or not). Repeating templates are left out: Things
    /// shows their instances, not them.
    private static func openTasks(in areaID: String, connection: Connection) throws -> [ThingsTask] {
        let sql = """
        SELECT t.uuid, t.title, t.notes, p.title, t.deadline
        FROM TMTask t
        LEFT JOIN TMTask h ON h.uuid = t.heading
        LEFT JOIN TMTask p ON p.uuid = COALESCE(t.project, h.project)
        WHERE t.type = 0 AND t.status = 0 AND t.trashed = 0
          AND t.rt1_recurrenceRule IS NULL
          AND (
            (t.area = ?1 AND p.uuid IS NULL)
            OR (p.area = ?1 AND p.status = 0 AND p.trashed = 0)
          )
        ORDER BY (p.uuid IS NOT NULL), p."index", h."index", t."index"
        """
        var order = 0
        return try connection.rows(sql, bind: [areaID]) { statement in
            defer { order += 1 }
            return ThingsTask(
                id: statement.text(0) ?? "",
                title: statement.text(1) ?? "",
                notes: statement.text(2) ?? "",
                projectTitle: statement.text(3),
                deadline: statement.integer(4).flatMap(ThingsDate.components(packed:)),
                order: order
            )
        }
    }

    /// One read-only connection, closed when it goes out of scope.
    private final class Connection {
        private var handle: OpaquePointer?

        init(url: URL) throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                sqlite3_close(handle)
                handle = nil
                throw ThingsDatabaseError.unreadable(message)
            }
            // Things writes while we read; wait a moment rather than fail.
            sqlite3_busy_timeout(handle, 750)
        }

        deinit { sqlite3_close(handle) }

        func rows<Row>(_ sql: String, bind values: [String] = [], map: (Statement) throws -> Row) throws -> [Row] {
            var raw: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else {
                throw ThingsDatabaseError.query(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(raw) }
            // SQLite copies the text right away (SQLITE_TRANSIENT).
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in values.enumerated() {
                sqlite3_bind_text(raw, Int32(index + 1), value, -1, transient)
            }
            let statement = Statement(raw: raw)
            var result: [Row] = []
            while true {
                let step = sqlite3_step(raw)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw ThingsDatabaseError.query(String(cString: sqlite3_errmsg(handle)))
                }
                result.append(try map(statement))
            }
            return result
        }
    }

    private struct Statement {
        let raw: OpaquePointer

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(raw, column) != SQLITE_NULL,
                  let pointer = sqlite3_column_text(raw, column) else { return nil }
            return String(cString: pointer)
        }

        func integer(_ column: Int32) -> Int? {
            guard sqlite3_column_type(raw, column) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(raw, column))
        }
    }
}

enum ThingsDatabaseError: Error, LocalizedError, Equatable {
    /// No Things database on this Mac.
    case notInstalled
    case unreadable(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Things 3 is not installed on this Mac."
        case .unreadable(let message): return "Portly could not open the Things database (\(message))."
        case .query(let message): return "Portly could not read the Things database (\(message))."
        }
    }
}

/// Changes go through Things' URL scheme, so Things records them and syncs
/// them to the phone. Opened in the background: Things never comes forward.
enum ThingsLinks {
    static func add(title: String, areaID: String) -> URL? {
        build("add", ["title": title, "list-id": areaID])
    }

    static func complete(taskID: String, token: String) -> URL? {
        build("update", ["id": taskID, "completed": "true", "auth-token": token])
    }

    static func show(taskID: String) -> URL? {
        build("show", ["id": taskID])
    }

    /// Every value is fully escaped: a `/` or `&` left as is would cut the
    /// title short or start another parameter.
    static func build(_ command: String, _ parameters: [String: String]) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let query = parameters
            .sorted { $0.key < $1.key }
            .compactMap { key, value in
                value.addingPercentEncoding(withAllowedCharacters: allowed).map { "\(key)=\($0)" }
            }
            .joined(separator: "&")
        return URL(string: "things:///\(command)?\(query)")
    }

    static func openInBackground(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }
}
