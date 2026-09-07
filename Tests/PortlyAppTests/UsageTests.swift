@testable import PortlyApp
import XCTest

/// Guards the shape of Claude's `GET /api/oauth/usage`. It is not a published
/// API, so these fail first if Anthropic changes it.
final class ClaudeUsageResponseTests: XCTestCase {
    private func decode(_ json: String) throws -> ClaudeUsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        return try decoder.decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    }

    /// Trimmed from a real response: the endpoint returns a long tail of
    /// null-valued keys that must not trip decoding.
    private let live = """
    {
      "five_hour": { "utilization": 52.0, "resets_at": "2026-08-28T09:50:00.316290+00:00",
                     "limit_dollars": null, "used_dollars": null },
      "seven_day": { "utilization": 17.0, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
      "seven_day_opus": null,
      "limits": [
        { "kind": "session", "group": "session", "percent": 52, "severity": "normal",
          "resets_at": "2026-08-28T09:50:00.316290+00:00", "scope": null, "is_active": true },
        { "kind": "weekly_all", "group": "weekly", "percent": 17, "severity": "normal",
          "resets_at": "2026-09-02T17:00:00.316321+00:00", "scope": null, "is_active": false }
      ]
    }
    """

    func testDecodesTheLiveShape() throws {
        let windows = try decode(live).limitWindows()
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].id, "session")
        XCTAssertEqual(windows[0].label, "Current session")
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.52, accuracy: 0.0001)
        XCTAssertEqual(windows[1].label, "All models")
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.17, accuracy: 0.0001)
    }

    /// Fable draws on the weekly allowance with its own cap, so the endpoint
    /// reports it as a weekly kind of its own. It must land right after the
    /// all-models window, labelled the way the usage panel writes it, and
    /// ahead of the older per-model windows.
    func testFableWeeklyWindowIsLabelledAndOrdered() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_opus", "percent": 30, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "weekly_fable", "percent": 61, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "weekly_all", "percent": 17, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "session", "percent": 52, "resets_at": "2026-08-28T09:50:00.316290+00:00" } ] }
        """
        let windows = try decode(json).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all", "weekly_fable", "weekly_opus"])
        XCTAssertEqual(windows[2].label, "Fable")
        XCTAssertEqual(windows[2].usedFraction ?? -1, 0.61, accuracy: 0.0001)
    }

    /// A named `seven_day_fable` window fills in when the kind has just rolled
    /// over and dropped out of `limits`.
    func testNamedFableWindowIsMergedIn() throws {
        let json = """
        { "limits": [ { "kind": "session", "percent": 5, "resets_at": "2026-08-28T09:50:00.316290+00:00" } ],
          "seven_day_fable": { "utilization": 12.0, "resets_at": "2026-09-02T17:00:00.316321+00:00" } }
        """
        let windows = try decode(json).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_fable"])
        XCTAssertEqual(windows[1].label, "Fable")
    }

    /// A window with no reset time cannot show a countdown, so it is dropped
    /// rather than shown with a bogus date.
    func testDropsWindowsWithoutAResetTime() throws {
        let json = """
        { "limits": [ { "kind": "session", "percent": 5, "resets_at": null } ],
          "five_hour": { "utilization": 5.0, "resets_at": null } }
        """
        XCTAssertTrue(try decode(json).limitWindows().isEmpty)
    }

    func testFallsBackToTheNamedWindows() throws {
        let json = """
        { "five_hour": { "utilization": 48.0, "resets_at": "2026-08-28T09:50:00.316290+00:00" },
          "seven_day": { "utilization": 16.0, "resets_at": "2026-09-02T17:00:00.316321+00:00" } }
        """
        XCTAssertEqual(try decode(json).limitWindows().map(\.label), ["Current session", "All models"])
    }

    func testUnknownKindsGetAReadableLabel() {
        XCTAssertEqual(ClaudeUsageResponse.label(forKind: "weekly_mythos"), "Mythos")
        XCTAssertEqual(ClaudeUsageResponse.label(forKind: "weekly_cowork"), "Cowork")
    }

    /// The ring shows the session, the same window Claude Code's `/usage`
    /// leads with, even when a weekly window is closer to running out.
    func testHeadlineIsTheSessionNotTheMostConstrainedWindow() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_fable", "percent": 90, "resets_at": "2026-09-02T17:00:00.316321+00:00" },
            { "kind": "session", "percent": 20, "resets_at": "2026-08-28T09:50:00.316290+00:00" } ] }
        """
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
            status: .ok, windows: try decode(json).limitWindows(), headlineID: "session"
        )
        XCTAssertEqual(snapshot.headlineText, "20%")
        XCTAssertEqual(snapshot.mostConstrained?.id, "weekly_fable")
    }
}

final class ClaudeBackoffTests: XCTestCase {
    private func response(retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] }
        )!
    }

    func testReadsRetryAfterInSeconds() {
        XCTAssertEqual(ClaudeUsageProvider.retryAfter(from: response(retryAfter: "120")), 120)
    }

    func testMissingOrUnparseableHeaderFallsBackToTheDefault() {
        XCTAssertNil(ClaudeUsageProvider.retryAfter(from: response(retryAfter: nil)))
        XCTAssertNil(ClaudeUsageProvider.retryAfter(from: response(retryAfter: "soon")))
    }

    /// `Retry-After: 0` is the endpoint's actual answer, and obeying it
    /// literally is what keeps you rate limited.
    func testAZeroHintStillWaitsAMinuteAndDoubles() {
        XCTAssertEqual(ClaudeUsageProvider.backoff(forAttempt: 0, retryAfter: 0), 60)
        XCTAssertEqual(ClaudeUsageProvider.backoff(forAttempt: 1, retryAfter: nil), 120)
        XCTAssertEqual(ClaudeUsageProvider.backoff(forAttempt: 99, retryAfter: nil), 15 * 60)
        XCTAssertEqual(ClaudeUsageProvider.backoff(forAttempt: 0, retryAfter: 600), 600)
    }

    @MainActor
    func testRateLimitReadsAsStaleNotError() {
        XCTAssertTrue(UsageStore.status(for: UsageProviderError.rateLimited(retryAfter: 60)).isStale)
        XCTAssertEqual(UsageStore.status(for: UsageProviderError.needsAuth), .needsAuth)
        XCTAssertEqual(UsageStore.status(for: UsageProviderError.badResponse(status: 500)), .error("HTTP 500"))
    }

    @MainActor
    func testIdlePollingWaitsOutTheIntervalUnlessBusy() {
        XCTAssertTrue(UsageStore.shouldRefresh(isBusy: true, sinceLastAttempt: 1, idleInterval: 300))
        XCTAssertFalse(UsageStore.shouldRefresh(isBusy: false, sinceLastAttempt: 60, idleInterval: 300))
        XCTAssertTrue(UsageStore.shouldRefresh(isBusy: false, sinceLastAttempt: 300, idleInterval: 300))
    }
}

final class ClaudeProfileTests: XCTestCase {
    func testSlugsComeFromTheDirectoryConvention() {
        XCTAssertEqual(ClaudeProfile.slug(fromDirectoryName: ".claude-work"), "work")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude"))
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude.json"))
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude-"))
    }

    func testProviderIDsAndKeychainServices() {
        let home = URL(fileURLWithPath: "/Users/me")
        let personal = ClaudeProfile.default(home: home)
        let work = ClaudeProfile(slug: "work", configDirectory: home.appendingPathComponent(".claude-work"))

        XCTAssertEqual(personal.id, "claude")
        XCTAssertEqual(work.id, "claude-work")
        XCTAssertEqual(work.displayName, "Claude (work)")
        XCTAssertTrue(ClaudeProfile.isClaude(providerID: "claude-work"))
        XCTAssertFalse(ClaudeProfile.isClaude(providerID: "codex"))
        XCTAssertEqual(personal.keychainService, "Claude Code-credentials")
        XCTAssertTrue(work.keychainService.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(work.keychainService.count, "Claude Code-credentials-".count + 8)
    }

    /// Claude Code files a new keychain item on every rotation; the newest
    /// duplicate has to win, whatever order they were enumerated in.
    func testNewestKeychainDuplicateWins() {
        let old: [CFString: Any] = [
            kSecValuePersistentRef: Data([1]),
            kSecAttrModificationDate: Date(timeIntervalSince1970: 1_000),
        ]
        let new: [CFString: Any] = [
            kSecValuePersistentRef: Data([2]),
            kSecAttrModificationDate: Date(timeIntervalSince1970: 2_000),
        ]
        XCTAssertEqual(KeychainItem.winner(among: [old, new])?.persistentRef, Data([2]))
        XCTAssertEqual(KeychainItem.winner(among: [new, old])?.persistentRef, Data([2]))
        XCTAssertNil(KeychainItem.winner(among: []))
    }
}

final class UsageBandTests: XCTestCase {
    func testBandsMatchTheDesignFrame() {
        XCTAssertEqual(UsageBand.band(for: 0.21), .ample)
        XCTAssertEqual(UsageBand.band(for: 0.52), .watch)
        XCTAssertEqual(UsageBand.band(for: 0.73), .critical)
        XCTAssertEqual(UsageBand.band(for: 1.0), .exhausted)
    }
}

final class ResetCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRelativeUnderAnHourAndAbsoluteBeyond() {
        XCTAssertEqual(ResetCopy.text(for: now.addingTimeInterval(51 * 60), now: now), "Resets in 51 min")
        XCTAssertEqual(ResetCopy.text(for: now.addingTimeInterval(50 * 60 + 40), now: now), "Resets in 51 min")
        let atTheEdge = ResetCopy.text(for: now.addingTimeInterval(60 * 60), now: now)
        XCTAssertFalse(atTheEdge.contains("min"))
        XCTAssertTrue(atTheEdge.hasPrefix("Resets "))
        XCTAssertEqual(ResetCopy.text(for: now.addingTimeInterval(-5), now: now), "Resetting…")
    }

    func testElapsedCopy() {
        XCTAssertEqual(ElapsedCopy.ago(since: now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(ElapsedCopy.ago(since: now.addingTimeInterval(-5 * 60), now: now), "5 min ago")
        XCTAssertEqual(ElapsedCopy.text(since: now.addingTimeInterval(-90 * 60), now: now), "1 hr 30 min")
    }
}

final class OtherProviderUsageTests: XCTestCase {
    func testCodexReadsBothWindowsAndLabelsByLength() throws {
        let json = """
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1800600000}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}]}
        """
        let result = try CodexUsage.windows(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10])
        XCTAssertEqual(CodexUsage.label(windowSeconds: 2_592_000, fallback: "primary"), "Monthly limit")
    }

    func testCursorReadsThePercentageTheDashboardShows() throws {
        let json = """
        {"billingCycleEnd":"2026-09-24T03:32:15.933Z","membershipType":"free","isUnlimited":false,
         "individualUsage":{
           "plan":{"enabled":true,"used":0,"limit":0,"remaining":0,
                   "autoPercentUsed":0,"apiPercentUsed":19,"totalPercentUsed":9.5},
           "onDemand":{"enabled":false,"used":0,"limit":null}}}
        """
        let windows = try CursorUsage.windows(fromJSON: json)
        XCTAssertEqual(windows.map(\.id), ["included", "api"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.095, accuracy: 0.0001)
        XCTAssertEqual(windows[0].summary, "10% Used · 90% left")
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testGrokCreditsAreTheWeeklyRing() throws {
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
        "end":"2026-09-12T08:21:18.802818+00:00"},
        "creditUsagePercent":8.0,
        "productUsage":[{"product":"GrokBuild","usagePercent":8.0}]}}
        """
        let windows = try GrokUsage.windows(creditsJSON: json)
        let credits = try XCTUnwrap(windows.first { $0.id == "credits" })
        XCTAssertEqual(credits.label, "Grok Build")
        XCTAssertEqual(credits.usedFraction ?? -1, 0.08, accuracy: 0.0001)
        XCTAssertNotNil(credits.resetsAt)
        XCTAssertThrowsError(try GrokUsage.windows(creditsJSON: #"{"config":{}}"#))
    }
}

final class UsageArchiveTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "UsageArchiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let reading = ProviderSnapshot(
        id: "claude", displayName: "Claude", glyph: .claude,
        fidelity: .official, status: .ok,
        windows: [
            LimitWindow(id: "session", label: "Current session",
                        usedFraction: 0.68, resetsAt: Date(timeIntervalSince1970: 1_787_910_000))
        ],
        headlineID: "session"
    )

    /// A restored reading comes back dated and stale, never presented as live.
    func testRoundTripsAndComesBackStale() throws {
        let defaults = makeDefaults()
        let taken = Date(timeIntervalSince1970: 1_787_900_000)
        UsageArchive(defaults: defaults).save(["claude": (reading, taken)])

        let restored = try XCTUnwrap(UsageArchive(defaults: defaults).load()["claude"])
        XCTAssertEqual(restored.snapshot.windows.first?.usedFraction, 0.68)
        XCTAssertEqual(restored.snapshot.headlineID, "session")
        XCTAssertEqual(restored.fetchedAt, taken)
        XCTAssertTrue(restored.snapshot.status.isStale)

        UsageArchive(defaults: defaults).forget("claude")
        XCTAssertTrue(UsageArchive(defaults: defaults).load().isEmpty)
    }

    @MainActor
    func testPreferencesDefaultToClaudeOnly() {
        let defaults = makeDefaults()
        let preferences = UsagePreferences(defaults: defaults, defaultEnabled: ["claude"])
        XCTAssertTrue(preferences.isEnabled("claude"))
        XCTAssertFalse(preferences.isEnabled("codex"))

        preferences.setEnabled(true, for: "codex")
        preferences.headline = .mostConstrained
        preferences.showPerModelWindows = false
        let reloaded = UsagePreferences(defaults: defaults, defaultEnabled: ["claude"])
        XCTAssertEqual(reloaded.enabledProviders, ["claude", "codex"])
        XCTAssertEqual(reloaded.notchVisibility, .onHover)
        XCTAssertEqual(reloaded.notchEdge, .right)
        XCTAssertTrue(reloaded.showInSidebar)
        XCTAssertTrue(reloaded.showInMenuBar)
        XCTAssertTrue(reloaded.showSessions)
        XCTAssertEqual(reloaded.headline, .mostConstrained)
        XCTAssertFalse(reloaded.showPerModelWindows)
    }

    /// The display preferences reshape a reading without touching the store:
    /// hiding the per-model windows drops Fable, and following the most
    /// constrained window moves the ring off the session.
    @MainActor
    func testDisplayPreferencesShapeTheReading() {
        let session = LimitWindow(id: "session", label: "Current session", usedFraction: 0.2, resetsAt: Date())
        let week = LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.4, resetsAt: Date())
        let fable = LimitWindow(id: "weekly_fable", label: "Fable", usedFraction: 0.9, resetsAt: Date())
        let full = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
                                    status: .ok, windows: [session, week, fable], headlineID: "session")

        let defaults = makeDefaults()
        let preferences = UsagePreferences(defaults: defaults, defaultEnabled: ["claude"])
        XCTAssertEqual(UsageCenter.shape([full], for: preferences).first?.headlineText, "20%")
        XCTAssertEqual(UsageCenter.shape([full], for: preferences).first?.windows.count, 3)

        preferences.headline = .mostConstrained
        XCTAssertEqual(UsageCenter.shape([full], for: preferences).first?.headlineText, "90%")
        XCTAssertEqual(UsageCenter.shape([full], for: preferences).first?.headline?.id, "weekly_fable")

        preferences.showPerModelWindows = false
        let shaped = UsageCenter.shape([full], for: preferences).first
        XCTAssertEqual(shaped?.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(shaped?.headlineText, "40%", "the hidden Fable window must not stay the headline")
    }
}

/// The notch layout is a scaled copy of Codenotch's design frame; these pin
/// the ratios the frame fixes.
final class NotchLayoutTests: XCTestCase {
    func testRingIsTheSpecAnchor() {
        XCTAssertEqual(NotchLayout.ringDiameter, 44, accuracy: 0.001)
        XCTAssertEqual(NotchLayout.bodyDepth(for: .right) / NotchLayout.ringDiameter, 186.0 / 117.0, accuracy: 0.001)
    }

    func testShapeGrowsOneCellAtATime() {
        let one = NotchLayout.shapeLength(cellCount: 1)
        let two = NotchLayout.shapeLength(cellCount: 2)
        XCTAssertEqual(two - one, NotchLayout.cellExtent + NotchLayout.cellSpacing, accuracy: 0.001)
    }

    /// Claude can expose five windows once Fable has its own weekly line, and
    /// the panel is sized once for the worst card.
    func testCardBudgetsForFiveWindows() {
        XCTAssertEqual(NotchLayout.maxWindowCount, 5)
        XCTAssertGreaterThan(NotchLayout.cardHeight(windowCount: 5), NotchLayout.cardHeight(windowCount: 4))
    }

    func testPanelHugsTheChosenEdge() {
        struct Screen: ScreenDescribing {
            let frameValue = CGRect(x: 0, y: 0, width: 1512, height: 982)
            let visibleFrameValue = CGRect(x: 0, y: 80, width: 1512, height: 870)
        }
        let size = CGSize(width: 300.4, height: 500.2)
        let right = NotchGeometry.panelFrame(for: Screen(), panelSize: size, edge: .right)
        XCTAssertEqual(right.maxX, 1512)
        XCTAssertEqual(right.width, 301)
        let bottom = NotchGeometry.panelFrame(for: Screen(), panelSize: size, edge: .bottom)
        XCTAssertEqual(bottom.minY, 80)
    }
}
