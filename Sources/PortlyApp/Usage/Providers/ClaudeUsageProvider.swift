import Foundation

/// Reads the same usage endpoint Claude Code's own `/usage` uses, with the
/// OAuth token from the keychain. One instance per `ClaudeProfile`.
///
/// The numbers are Anthropic's, so this is `.official`. The endpoint is not a
/// published API, though, so every failure path degrades to a status the UI
/// can render honestly rather than to a guess.
actor ClaudeUsageProvider: UsageProvider {
    nonisolated let profile: ClaudeProfile
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.claude
    nonisolated private let keychain: ClaudeKeychain

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    /// Held between refreshes so the keychain is read once per token.
    private var credentials: ClaudeCredentials?
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network.
    private var retryNoEarlierThan: Date?
    /// How many 429s in a row. The endpoint answers `Retry-After: 0`, which is
    /// no guidance at all, so the wait doubles each time instead.
    private var consecutiveRateLimits = 0

    private let archive: UsageArchive
    /// Injected so the token path can be tested without a keychain.
    private let loadCredentials: @Sendable () throws -> ClaudeCredentials

    init(profile: ClaudeProfile = .default(),
         session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         loadCredentials: (@Sendable () throws -> ClaudeCredentials)? = nil) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        let keychain = ClaudeKeychain(profile: profile)
        self.keychain = keychain
        self.loadCredentials = loadCredentials ?? { try keychain.load() }
        self.session = session
        self.archive = archive
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: profile.id)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            UsageLog.usage.debug("skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }
        do {
            let snapshot = try await fetch(retryingOnUnauthorized: true)
            retryNoEarlierThan = nil
            consecutiveRateLimits = 0
            archive.saveBackoffUntil(nil, providerID: id)
            return snapshot
        } catch UsageProviderError.needsAuth {
            credentials = nil
            throw UsageProviderError.needsAuth
        } catch UsageProviderError.credentialExpired {
            credentials = nil
            throw UsageProviderError.credentialExpired
        } catch let error as UsageProviderError {
            if case .rateLimited(let retryAfter) = error {
                consecutiveRateLimits += 1
                retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
                archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
                UsageLog.usage.notice("rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            }
            throw error
        }
    }

    private func fetch(retryingOnUnauthorized: Bool) async throws -> ProviderSnapshot {
        let token = try currentToken()

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        UsageLog.usage.debug("GET /api/oauth/usage")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        UsageLog.usage.debug("usage endpoint answered \(status)")

        if status == 401 || status == 403 {
            // Rejected but unexpired: the held copy is wrong, which is what
            // signing into a different account looks like from here.
            keychain.forgetCached()
            credentials = nil
            if retryingOnUnauthorized {
                return try await fetch(retryingOnUnauthorized: false)
            }
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: Self.backoff(
                    forAttempt: consecutiveRateLimits,
                    retryAfter: Self.retryAfter(from: response)
                )
            )
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let payload = try Self.decoder.decode(ClaudeUsageResponse.self, from: data)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: payload.limitWindows(),
            headlineID: "session"
        )
    }

    private func currentToken() throws -> String {
        if let credentials, !credentials.isExpired {
            return credentials.accessToken
        }
        let fresh = try loadCredentials()
        UsageLog.usage.debug("\(self.id, privacy: .public): read keychain token, expires \(fresh.expiresAt, privacy: .public)")
        // Expired is not signed out: after a restart the token is usually
        // stale until Claude Code is next used, and the honest thing is to
        // keep showing the last reading with its age.
        guard !fresh.isExpired else { throw UsageProviderError.credentialExpired }
        credentials = fresh
        return fresh.accessToken
    }

    /// How long to wait after a 429. The server's own hint is honoured only as
    /// a floor-raiser: it answers `Retry-After: 0`. The wait starts at a
    /// minute and doubles for each 429 in a row, capped so it always recovers.
    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 15 * 60
        let doubled = floor * pow(2, Double(min(attempt, 4)))
        return min(ceiling, max(doubled, retryAfter ?? 0))
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    static func retryAfter(from response: URLResponse?) -> TimeInterval? {
        guard let header = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)
        else { return nil }

        if let seconds = TimeInterval(header) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Run `\(profile.signInCommand)` once — it signs in and refreshes "
                  + "the token this reads. Use /login there to change account.")
    }

    nonisolated func forgetCachedCredential() { keychain.forgetCached() }

    nonisolated var usageURL: URL? { Self.usagePage }

    private static let usagePage = URL(string: "https://claude.ai/settings/usage")

    nonisolated func account() -> ProviderAccount? {
        guard let credentials = try? keychain.load() else { return nil }
        return ProviderAccount(
            label: nil,
            plan: credentials.subscriptionType,
            source: profile.sourceName,
            manageURL: Self.usagePage
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Timestamps come back with fractional seconds and an offset, which
        // `.iso8601` alone will not parse.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601Dates.parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date \(text)")
            )
        }
        return decoder
    }()
}

/// The shape of `GET /api/oauth/usage`.
struct ClaudeUsageResponse: Decodable {
    struct Limit: Decodable {
        let kind: String
        let percent: Double
        let resetsAt: Date?
    }
    struct Window: Decodable {
        let utilization: Double
        let resetsAt: Date?
    }

    let limits: [Limit]?
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDayFable: Window?

    /// `limits` is the forward-compatible shape — it grows new kinds as
    /// Anthropic adds them, which is how a Fable weekly window appears without
    /// this code knowing about it in advance — so it is preferred, with the
    /// named windows merged in for older responses and for a window that has
    /// just rolled over and dropped out of the array.
    func limitWindows() -> [LimitWindow] {
        var windows = (limits ?? []).compactMap { limit -> LimitWindow? in
            guard let resetsAt = limit.resetsAt else { return nil }
            return LimitWindow(
                id: limit.kind,
                label: ClaudeUsageResponse.label(forKind: limit.kind),
                usedFraction: limit.percent / 100,
                resetsAt: resetsAt
            )
        }

        func merge(_ window: ClaudeUsageResponse.Window?, id: String) {
            guard let window, let resetsAt = window.resetsAt,
                  !windows.contains(where: { $0.id == id })
            else { return }
            windows.append(LimitWindow(id: id, label: ClaudeUsageResponse.label(forKind: id),
                                       usedFraction: window.utilization / 100,
                                       resetsAt: resetsAt))
        }
        merge(fiveHour, id: "session")
        merge(sevenDay, id: "weekly_all")
        merge(sevenDayOpus, id: "weekly_opus")
        merge(sevenDayFable, id: "weekly_fable")

        return windows.sorted(by: ClaudeUsageResponse.displayOrder)
    }

    /// The wording Claude's own usage panel uses for the kinds it knows, and a
    /// readable fallback for any it does not yet.
    static func label(forKind kind: String) -> String {
        switch kind {
        case "session": return "Current session"
        case "weekly_all": return "All models"
        case "weekly_fable": return "Fable"
        case "weekly_mythos": return "Mythos"
        case "weekly_opus": return "Opus"
        case "weekly_sonnet": return "Sonnet"
        default:
            return kind
                .replacingOccurrences(of: "weekly_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    /// Session first, then the all-models week, then the per-model weekly
    /// windows with the premium tier leading, the order the usage panel shows.
    private static func displayOrder(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        func rank(_ id: String) -> Int {
            switch id {
            case "session": return 0
            case "weekly_all": return 1
            case "weekly_fable", "weekly_mythos": return 2
            case "weekly_opus": return 3
            default: return 4
            }
        }
        let (ra, rb) = (rank(a.id), rank(b.id))
        return ra == rb ? a.id < b.id : ra < rb
    }
}
