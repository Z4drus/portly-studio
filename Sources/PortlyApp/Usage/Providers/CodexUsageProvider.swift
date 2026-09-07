import Foundation

/// Borrows Codex's local session without refreshing or changing its credentials.
enum CodexCredentials {
    struct Credential {
        let accessToken: String
        let accountID: String
    }

    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
    }

    static let bundleID = "com.openai.codex"
    static let usagePage = URL(string: "https://chatgpt.com/#settings/Account")

    static func load(from url: URL = authURL, now: Date = Date()) throws -> Credential {
        struct Auth: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let account_id: String
            }
            let tokens: Tokens
        }
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONDecoder().decode(Auth.self, from: data),
              !auth.tokens.access_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !auth.tokens.account_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw UsageProviderError.needsAuth }

        if let expiry = claims(inJWT: auth.tokens.access_token)?["exp"] as? Double,
           expiry <= now.timeIntervalSince1970 {
            throw UsageProviderError.credentialExpired
        }
        return Credential(accessToken: auth.tokens.access_token, accountID: auth.tokens.account_id)
    }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = claims(inJWT: idToken)
        else { return nil }

        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return ProviderAccount(
            label: claims["email"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String,
            source: "Codex",
            manageURL: usagePage
        )
    }

    /// Claims supply identity labels and a local expiry hint. The server
    /// validates the token.
    static func claims(inJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Only the account's main rate-limit windows belong in the usage rings.
/// `additional_rate_limits` and `code_review_rate_limit` meter something else.
enum CodexUsage {
    private struct Response: Decodable {
        let rate_limit: RateLimit?
    }

    private struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }

    private struct Window: Decodable {
        let limit_window_seconds: Double
        let used_percent: Double?
        let reset_at: Double?
        let reset_after_seconds: Double?
    }

    static func windows(from data: Data, now: Date = Date()) throws -> [LimitWindow] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageProviderError.badResponse(status: 0)
        }

        var windows: [LimitWindow] = []
        for (id, window) in [("primary", response.rate_limit?.primary_window),
                             ("secondary", response.rate_limit?.secondary_window)] {
            guard let window else { continue }
            guard let percent = window.used_percent else {
                throw UsageProviderError.badResponse(status: 0)
            }
            let resetsAt = window.reset_at.map { Date(timeIntervalSince1970: $0) }
                ?? window.reset_after_seconds.map { now.addingTimeInterval($0) }
            windows.append(LimitWindow(
                id: id,
                label: label(windowSeconds: window.limit_window_seconds, fallback: id),
                usedFraction: percent / 100,
                resetsAt: resetsAt
            ))
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("Codex reported no usage windows")
        }
        return windows
    }

    /// The plan decides what the primary window actually is — a free plan has
    /// shown a 30-day window here, not the 5-hour one a paid plan reports — so
    /// the label is derived from the length Codex sent rather than assumed.
    static func label(windowSeconds: Double, fallback: String) -> String {
        guard windowSeconds > 0 else {
            return fallback == "primary" ? "Current session" : "Longer window"
        }
        let minutes = windowSeconds / 60
        if minutes < 60 { return "\(Int(minutes))m limit" }
        if minutes < 60 * 24 { return "\(Int(minutes / 60))h limit" }
        let days = Int((minutes / (60 * 24)).rounded())
        switch days {
        case 7: return "Weekly limit"
        case 30: return "Monthly limit"
        default: return "\(days)d limit"
        }
    }
}

/// Reads live account limits using the session owned and refreshed by Codex.
actor CodexUsageProvider: UsageProvider {
    nonisolated let id = "codex"
    nonisolated let displayName = "Codex"
    nonisolated let glyph = ProviderGlyph.openai

    private let session: URLSession
    nonisolated private let authURL: URL
    private let archive: UsageArchive
    private var retryNoEarlierThan: Date?

    init(session: URLSession = .shared,
         authURL: URL = CodexCredentials.authURL,
         archive: UsageArchive = UsageArchive()) {
        self.session = session
        self.authURL = authURL
        self.archive = archive
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: "codex")
    }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: CodexCredentials.bundleID, name: "Codex")
    }

    nonisolated func account() -> ProviderAccount? { CodexCredentials.account(from: authURL) }

    nonisolated var usageURL: URL? { CodexCredentials.usagePage }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let now = Date()
        if let retryNoEarlierThan, retryNoEarlierThan > now {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSince(now))
        }

        // Codex can rotate its token between polls; this app never writes it.
        let credential = try CodexCredentials.load(from: authURL)
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            let receivedAt = Date()
            let delay = max(60, ClaudeUsageProvider.retryAfter(from: http) ?? 0)
            retryNoEarlierThan = receivedAt.addingTimeInterval(delay)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let windows = try CodexUsage.windows(from: data)
        retryNoEarlierThan = nil
        archive.saveBackoffUntil(nil, providerID: id)
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: windows,
            headlineID: windows.first?.id
        )
    }
}
