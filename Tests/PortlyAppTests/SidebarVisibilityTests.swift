import Foundation
import PortlyCore
import XCTest
@testable import PortlyApp

final class SidebarVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    private func shouldArchive(
        lastActivity: Date?,
        running: Bool = false,
        working: Bool = false,
        selected: Bool = false,
        days: Int = 1
    ) -> Bool {
        SidebarVisibility.shouldAutoArchive(
            lastActivity: lastActivity,
            hasRunningServer: running,
            isWorking: working,
            isSelected: selected,
            afterDays: days,
            now: now
        )
    }

    func testIdleProjectsArchiveAfterTheConfiguredDays() {
        XCTAssertFalse(shouldArchive(lastActivity: hoursAgo(23.9)))
        XCTAssertTrue(shouldArchive(lastActivity: hoursAgo(24.1)))
        XCTAssertTrue(shouldArchive(lastActivity: nil), "a project nobody ever worked on is idle")
        XCTAssertFalse(shouldArchive(lastActivity: hoursAgo(24 * 2.9), days: 3))
        XCTAssertTrue(shouldArchive(lastActivity: hoursAgo(24 * 3.1), days: 3))
    }

    func testZeroDaysNeverArchives() {
        XCTAssertFalse(shouldArchive(lastActivity: nil, days: 0))
        XCTAssertFalse(shouldArchive(lastActivity: hoursAgo(24 * 365), days: 0))
    }

    func testAProjectInUseNeverArchivesItself() {
        let old = hoursAgo(24 * 90)
        XCTAssertFalse(shouldArchive(lastActivity: old, running: true))
        XCTAssertFalse(shouldArchive(lastActivity: old, working: true))
        XCTAssertFalse(shouldArchive(lastActivity: old, selected: true))
    }

    private func projects(_ names: String...) -> [Project] {
        names.map { Project(name: $0, root: "/tmp/\($0)") }
    }

    func testOrderPutsKnownProjectsFirstThenTheRestInConfigurationOrder() {
        let list = projects("a", "b", "c", "d")
        let ordered = SidebarVisibility.ordered(list, order: [list[2].id, "gone", list[0].id])
        XCTAssertEqual(ordered.map(\.name), ["c", "a", "b", "d"])
    }

    func testCompleteDropsDeletedProjectsAndAddsNewOnes() {
        let list = projects("a", "b", "c")
        let order = SidebarVisibility.complete(["gone", list[1].id], projects: list)
        XCTAssertEqual(order, [list[1].id, list[0].id, list[2].id])
    }

    func testMovingToTopKeepsEveryOtherProjectInPlace() {
        let list = projects("a", "b", "c", "d")
        let ids = list.map(\.id)
        let order = SidebarVisibility.movingToTop(ids[2], in: ids, projects: list)
        XCTAssertEqual(order, [ids[2], ids[0], ids[1], ids[3]])
        XCTAssertEqual(SidebarVisibility.movingToTop(ids[0], in: ids, projects: list), ids)
    }

    func testANewProjectCanGoToTheTopBeforeTheListKnowsIt() {
        let list = projects("a", "b")
        let order = SidebarVisibility.movingToTop("new", in: list.map(\.id), projects: list)
        XCTAssertEqual(order.first, "new")
        XCTAssertEqual(order.count, 3)
    }

    func testDraggingTakesThePlaceOfTheRowPassedOver() {
        let list = projects("a", "b", "c", "d")
        let ids = list.map(\.id)
        // Down: a over c lands after c.
        XCTAssertEqual(
            SidebarVisibility.moving(ids[0], onto: ids[2], in: ids, projects: list),
            [ids[1], ids[2], ids[0], ids[3]]
        )
        // Up: d over b lands before b.
        XCTAssertEqual(
            SidebarVisibility.moving(ids[3], onto: ids[1], in: ids, projects: list),
            [ids[0], ids[3], ids[1], ids[2]]
        )
        XCTAssertEqual(SidebarVisibility.moving(ids[1], onto: ids[1], in: ids, projects: list), ids)
    }

    func testStepsSkipArchivedProjects() {
        let list = projects("a", "archived", "b", "c")
        let ids = list.map(\.id)
        let visible = [ids[0], ids[2], ids[3]]
        // b one step up passes the archived project and lands before a.
        XCTAssertEqual(
            SidebarVisibility.moving(ids[2], by: -1, among: visible, in: ids, projects: list),
            [ids[2], ids[0], ids[1], ids[3]]
        )
        // Already at the bottom: nothing moves.
        XCTAssertEqual(SidebarVisibility.moving(ids[3], by: 1, among: visible, in: ids, projects: list), ids)
    }

    func testSearchRanksNamePrefixThenRecency() {
        let projects = [
            Project(name: "Shop API", root: "/tmp/shop-api"),
            Project(name: "API Gateway", root: "/tmp/gateway"),
            Project(name: "Landing", root: "/tmp/clients/api-landing"),
            Project(name: "Café Créole", root: "/tmp/cafe"),
        ]
        let activity: [String: Date] = [projects[0].id: hoursAgo(2), projects[1].id: hoursAgo(200)]

        let hits = SidebarVisibility.search(projects, query: " api ") { activity[$0] }
        XCTAssertEqual(hits.map(\.name), ["API Gateway", "Shop API", "Landing"])

        XCTAssertEqual(SidebarVisibility.search(projects, query: "cafe creole") { _ in nil }.map(\.name), ["Café Créole"])

        let everything = SidebarVisibility.search(projects, query: "") { activity[$0] }
        XCTAssertEqual(everything.first?.name, "Shop API", "no query lists the most recently used first")
        XCTAssertEqual(everything.count, projects.count)
    }

    func testOlderConfigsDecodeWithoutTheSidebarState() throws {
        let json = Data(#"{"version":1,"sessions":[]}"#.utf8)
        let config = try JSONDecoder().decode(StudioConfig.self, from: json)
        XCTAssertEqual(config.projectActivity, [:])
        XCTAssertEqual(config.archivedProjects, [])
        XCTAssertEqual(config.projectOrder, [])
        XCTAssertEqual(config.autoArchiveDays, StudioConfig.defaultAutoArchiveDays)
        XCTAssertEqual(config.version, 1, "an old file must still be migrated")
        XCTAssertEqual(StudioConfig().version, StudioConfig.currentVersion, "a new one needs no migration")
    }

    func testSidebarStateSurvivesARoundTrip() throws {
        var config = StudioConfig()
        config.archivedProjects = ["prj_a"]
        config.projectOrder = ["prj_b", "prj_a"]
        config.autoArchiveDays = 7
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StudioConfig.self, from: encoder.encode(config))
        XCTAssertEqual(decoded.archivedProjects, ["prj_a"])
        XCTAssertEqual(decoded.projectOrder, ["prj_b", "prj_a"])
        XCTAssertEqual(decoded.autoArchiveDays, 7)
    }

    // MARK: - Transcript activity

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testLastExchangeIgnoresTheBookkeepingAResumeWrites() {
        let text = [
            line(["type": "user", "timestamp": "2026-09-16T13:50:00.000Z"]),
            line(["type": "assistant", "timestamp": "2026-09-16T13:56:03.633Z"]),
            line(["type": "cost-state", "totalCostUSD": 0.7]),
            line(["type": "system", "timestamp": "2026-09-27T07:21:05.000Z"]),
            line(["type": "cost-state", "totalCostUSD": 0.7]),
        ].joined(separator: "\n") + "\n"
        let date = ClaudeTranscripts.lastExchange(inTail: Data(text.utf8), isWholeFile: true)
        XCTAssertEqual(date, ClaudeTranscripts.parseTimestamp("2026-09-16T13:56:03.633Z"))
    }

    func testLastExchangeSkipsThePartialFirstLineOfATail() {
        let partial = #"ant","timestamp":"2030-01-01T00:00:00Z"}"#
        let text = partial + "\n" + line(["type": "user", "timestamp": "2026-09-01T10:00:00Z"])
        let date = ClaudeTranscripts.lastExchange(inTail: Data(text.utf8), isWholeFile: false)
        XCTAssertEqual(date, ClaudeTranscripts.parseTimestamp("2026-09-01T10:00:00Z"))
        XCTAssertNil(ClaudeTranscripts.lastExchange(inTail: Data(partial.utf8), isWholeFile: false))
    }
}
