import Foundation
import SQLite3

/// Read-only access to another app's SQLite store.
///
/// Cursor runs its state in WAL mode, which makes opening it delicate:
/// `immutable=1` ignores the write-ahead log, so a running editor's most
/// recent writes are invisible; `mode=ro` sees the log but needs the `-shm`
/// sidecar, which exists only while the editor is running. So `mode=ro`
/// first, `immutable=1` second.
enum SQLiteStore {
    static func open(_ url: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        for query in ["mode=ro", "immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2("file:\(url.path)?\(query)", &db,
                               SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               let db {
                return db
            }
            sqlite3_close(db)
        }
        return nil
    }

    /// First column of every row, as text.
    static func rows(in db: OpaquePointer?, sql: String, bind: String? = nil) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        if let bind {
            sqlite3_bind_text(statement, 1, bind, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { out.append(String(cString: raw)) }
        }
        return out
    }
}

/// The session Cursor's editor keeps for itself, in the SQLite global-state
/// store it inherits from VS Code. Portly only ever reads it.
struct CursorCredentials {
    let accountID: String
    let accessToken: String
    /// The web API wants the pair as one cookie.
    var sessionCookie: String { "WorkosCursorSessionToken=\(accountID)::\(accessToken)" }

    static var storeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Minted by ToDesktop, who build Cursor — stable across updates.
    static let bundleID = "com.todesktop.230313mzl4w4u92"
    static let usagePage = URL(string: "https://cursor.com/dashboard")

    /// Identity, read from the same store as the session. Non-secret: the
    /// email and plan the editor caches for its own UI.
    static func account(from url: URL = storeURL) -> ProviderAccount? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }
        guard let email = value(forKey: "cursorAuth/cachedEmail", in: db), !email.isEmpty else { return nil }
        return ProviderAccount(
            label: email,
            plan: value(forKey: "cursorAuth/stripeMembershipType", in: db),
            source: "Cursor",
            manageURL: usagePage
        )
    }

    static func load(from url: URL = storeURL) throws -> CursorCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageProviderError.needsAuth
        }
        guard let db = SQLiteStore.open(url) else { throw UsageProviderError.needsAuth }
        defer { sqlite3_close(db) }

        guard let token = value(forKey: "cursorAuth/accessToken", in: db),
              let account = value(forKey: "cursorAuth/stripeMembershipAuthId", in: db),
              !token.isEmpty, !account.isEmpty
        else { throw UsageProviderError.needsAuth }

        return CursorCredentials(accountID: account, accessToken: token)
    }

    private static func value(forKey key: String, in db: OpaquePointer?) -> String? {
        SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: key).first
    }
}

/// Parses Cursor's `GET /api/usage-summary`. Cursor meters an allowance, not
/// a request count: the dashboard's "Your included usage · N% used" is
/// `totalPercentUsed`, and the `used`/`limit` pair sits at zero on a free
/// plan even while real usage is happening.
enum CursorUsage {
    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let resetsAt = date(root["billingCycleEnd"])
        let usage = root["individualUsage"] as? [String: Any] ?? [:]
        let plan = usage["plan"] as? [String: Any] ?? [:]

        var windows: [LimitWindow] = []

        // Zero is a reading, not an absence: Cursor itself says "You've used
        // 0% of your included total usage".
        if let total = percent(plan["totalPercentUsed"]) {
            windows.append(LimitWindow(id: "included", label: "Included usage",
                                       usedFraction: total, resetsAt: resetsAt))
        }
        if let api = percent(plan["apiPercentUsed"]), api > 0 {
            windows.append(LimitWindow(id: "api", label: "API usage",
                                       usedFraction: api, resetsAt: resetsAt))
        }
        if let onDemand = spendWindow(usage["onDemand"], id: "on_demand",
                                      label: "On demand", resetsAt: resetsAt) {
            windows.append(onDemand)
        }

        guard windows.isEmpty else { return windows }

        let membership = (root["membershipType"] as? String) ?? "this"
        if (root["isUnlimited"] as? Bool) == true {
            throw UsageProviderError.nothingMetered("Unlimited on the \(membership) plan — nothing to meter")
        }
        throw UsageProviderError.nothingMetered("The \(membership) plan has nothing for Cursor to meter yet")
    }

    /// A dollar-denominated bucket, used where a plan states a real ceiling.
    private static func spendWindow(
        _ any: Any?, id: String, label: String, resetsAt: Date?
    ) -> LimitWindow? {
        guard let bucket = any as? [String: Any],
              (bucket["enabled"] as? Bool) == true,
              let limit = (bucket["limit"] as? NSNumber)?.doubleValue, limit > 0,
              let used = (bucket["used"] as? NSNumber)?.doubleValue
        else { return nil }
        return LimitWindow(id: id, label: label, usedFraction: used / limit, resetsAt: resetsAt)
    }

    /// Cursor reports 0–100; the rest of the app works in 0–1.
    private static func percent(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber else { return nil }
        return number.doubleValue / 100
    }

    private static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        return ISO8601Dates.parse(text)
    }
}

/// ISO 8601 with or without fractional seconds, which vendors mix freely.
enum ISO8601Dates {
    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// Reads Cursor usage as the account the *editor* is signed into, so there is
/// only ever one account: the one actually being used.
actor CursorUsageProvider: UsageProvider {
    nonisolated let id = "cursor"
    nonisolated let displayName = "Cursor"
    nonisolated let glyph = ProviderGlyph.cursor

    private let endpoint = URL(string: "https://cursor.com/api/usage-summary")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: CursorCredentials.bundleID, name: "Cursor")
    }

    nonisolated func account() -> ProviderAccount? { CursorCredentials.account() }

    nonisolated var usageURL: URL? { CursorCredentials.usagePage }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Re-read every time: the editor rotates this.
        let credentials = try CursorCredentials.load()

        var request = URLRequest(url: endpoint)
        request.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: try CursorUsage.windows(fromJSON: body),
            headlineID: "included"
        )
    }
}
