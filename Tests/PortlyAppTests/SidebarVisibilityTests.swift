import Foundation
import PortlyCore
import XCTest
@testable import PortlyApp

final class SidebarVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    func testARunningServerKeepsAProjectListedHoweverOldItIs() {
        XCTAssertTrue(SidebarVisibility.isVisible(
            hasRunningServer: true, lastActivity: hoursAgo(24 * 90), isSelected: false, now: now
        ))
    }

    func testActivityCountsForADay() {
        XCTAssertTrue(SidebarVisibility.isVisible(
            hasRunningServer: false, lastActivity: hoursAgo(23.9), isSelected: false, now: now
        ))
        XCTAssertFalse(SidebarVisibility.isVisible(
            hasRunningServer: false, lastActivity: hoursAgo(24.1), isSelected: false, now: now
        ))
        XCTAssertFalse(SidebarVisibility.isVisible(
            hasRunningServer: false, lastActivity: nil, isSelected: false, now: now
        ))
    }

    func testTheProjectOnScreenNeverDisappears() {
        XCTAssertTrue(SidebarVisibility.isVisible(
            hasRunningServer: false, lastActivity: nil, isSelected: true, now: now
        ))
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

    func testOlderConfigsDecodeWithoutProjectActivity() throws {
        let json = Data(#"{"version":1,"sessions":[]}"#.utf8)
        let config = try JSONDecoder().decode(StudioConfig.self, from: json)
        XCTAssertEqual(config.projectActivity, [:])
    }
}
