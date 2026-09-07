import Foundation

/// Identity and token from `~/.grok/auth.json`. Grok CLI signs in through
/// `auth.x.ai` and writes the session here; Portly only reads it.
struct GrokCredentials {
    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
    }

    static let usagePage = URL(string: "https://grok.com/?_s=usage")

    let accessToken: String
    let expiresAt: Date
    let email: String?

    var isExpired: Bool { expiresAt <= Date() }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard let stored = (try? load(from: url)) else { return nil }
        return ProviderAccount(
            label: stored.email,
            plan: nil,
            source: "Grok",
            manageURL: usagePage
        )
    }

    static func load(from url: URL = authURL) throws -> GrokCredentials {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = pick(from: root)
        else { throw UsageProviderError.needsAuth }

        guard let token = entry["key"] as? String, !token.isEmpty else {
            throw UsageProviderError.needsAuth
        }

        return GrokCredentials(
            accessToken: token,
            expiresAt: date(entry["expires_at"]) ?? Date().addingTimeInterval(30 * 24 * 60 * 60),
            email: entry["email"] as? String
        )
    }

    /// Only a session minted by xAI itself: Grok also supports a customer IdP
    /// whose token is meant for a private proxy, and sending that to the
    /// public endpoint would hand someone else's credential to it.
    static let trustedIssuer = "https://auth.x.ai"

    /// The file is keyed by `issuer::client_id`. If several sit there, the one
    /// that is still live wins, otherwise the first *trusted* entry.
    static func pick(from root: [String: Any]) -> [String: Any]? {
        let entries = root.compactMap { key, value -> [String: Any]? in
            guard let entry = value as? [String: Any], isTrusted(key: key, entry: entry)
            else { return nil }
            return entry
        }
        if let live = entries.first(where: {
            guard let expiry = date($0["expires_at"]) else { return true }
            return expiry > Date()
        }) { return live }
        return entries.first
    }

    static func isTrusted(key: String, entry: [String: Any]) -> Bool {
        if key.hasPrefix(trustedIssuer) { return true }
        if let issuer = entry["oidc_issuer"] as? String, issuer == trustedIssuer { return true }
        return false
    }

    static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        return ISO8601Dates.parse(text)
    }
}

/// Parses Grok CLI's credits endpoint: the weekly Grok Build allowance, the
/// one number this endpoint actually states.
enum GrokUsage {
    static func windows(creditsJSON: String) throws -> [LimitWindow] {
        guard let credits = object(creditsJSON)?["config"] as? [String: Any] else {
            throw UsageProviderError.badResponse(status: 0)
        }

        var windows: [LimitWindow] = []

        let creditsReset = GrokCredentials.date((credits["currentPeriod"] as? [String: Any])?["end"])
            ?? GrokCredentials.date(credits["billingPeriodEnd"])

        if let fraction = percent(credits["creditUsagePercent"]) {
            windows.append(LimitWindow(
                id: "credits",
                label: productLabel(credits) ?? "Grok Build",
                usedFraction: fraction,
                resetsAt: creditsReset
            ))
        } else if let products = credits["productUsage"] as? [[String: Any]] {
            for product in products {
                guard let fraction = percent(product["usagePercent"]) else { continue }
                let name = (product["product"] as? String).map(humanize) ?? "Usage"
                // The ring is declared as `headlineID: "credits"`, so the first
                // product has to carry that id.
                windows.append(LimitWindow(
                    id: windows.isEmpty ? "credits" : ((product["product"] as? String) ?? name),
                    label: name,
                    usedFraction: fraction,
                    resetsAt: creditsReset
                ))
            }
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("Grok has nothing metered on this account yet")
        }
        return windows
    }

    private static func productLabel(_ credits: [String: Any]) -> String? {
        guard let products = credits["productUsage"] as? [[String: Any]],
              let name = products.first?["product"] as? String
        else { return nil }
        return humanize(name)
    }

    /// "GrokBuild" → "Grok Build".
    static func humanize(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }
        return result
    }

    private static func percent(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber else { return nil }
        return number.doubleValue / 100
    }

    private static func object(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Reads Grok Build usage from the same billing endpoint the CLI's `/usage` uses.
actor GrokUsageProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "Grok"
    nonisolated let glyph = ProviderGlyph.grok

    private let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let session: URLSession
    private let authURL: URL

    init(session: URLSession = .shared, authURL: URL = GrokCredentials.authURL) {
        self.session = session
        self.authURL = authURL
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Run grok login — it signs in and refreshes the token this reads.")
    }

    nonisolated func account() -> ProviderAccount? { GrokCredentials.account() }

    nonisolated var usageURL: URL? { GrokCredentials.usagePage }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try GrokCredentials.load(from: authURL)
        if credentials.isExpired { throw UsageProviderError.credentialExpired }

        var request = URLRequest(url: creditsURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 { throw UsageProviderError.rateLimited(retryAfter: 60) }
        guard (200..<300).contains(status),
              let text = String(data: data, encoding: .utf8)
        else { throw UsageProviderError.badResponse(status: status) }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: try GrokUsage.windows(creditsJSON: text),
            headlineID: "credits"
        )
    }
}
