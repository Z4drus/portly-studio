import AppKit
import SwiftUI
@testable import PortlyApp
import PortlyCore
import XCTest

final class SidebarSearchTests: XCTestCase {
    private let lumail = Project(
        id: "prj_lumail",
        name: "lumail.io",
        root: "/Users/me/Developer/lumail.io",
        servers: [
            ServerConfig(id: "srv_dev", name: "dev", command: "pnpm dev", port: 3002),
            ServerConfig(id: "srv_redis", name: "redis", command: "redis-server", port: 8079),
        ]
    )
    private let nowTS = Project(
        id: "prj_now",
        name: "NOW.TS",
        root: "/Users/me/Developer/now.ts",
        servers: [
            ServerConfig(id: "srv_web", name: "web", command: "next dev", port: 3000),
        ]
    )

    private var catalog: [Project] { [lumail, nowTS] }

    func testEmptyQueryKeepsEveryProjectAndServer() {
        XCTAssertEqual(SidebarSearch.filterProjects(catalog, query: "  ").map(\.id), ["prj_lumail", "prj_now"])
        XCTAssertEqual(SidebarSearch.filterProjects(catalog, query: "  ")[0].servers.map(\.id), ["srv_dev", "srv_redis"])
        XCTAssertFalse(SidebarSearch.isActive("   "))
    }

    func testProjectNameMatchKeepsEveryServerInThatProject() {
        let result = SidebarSearch.filterProjects(catalog, query: "Lumail")

        XCTAssertEqual(result.map(\.id), ["prj_lumail"])
        XCTAssertEqual(result[0].servers.map(\.name), ["dev", "redis"])
    }

    func testFolderNameMatchFindsProjectWhenDisplayNameDiffers() {
        let result = SidebarSearch.filterProjects(catalog, query: "now.ts")

        XCTAssertEqual(result.map(\.id), ["prj_now"])
    }

    func testServerNameMatchKeepsOnlyThatServerUnderItsProject() {
        let result = SidebarSearch.filterProjects(catalog, query: "redis")

        XCTAssertEqual(result.map(\.id), ["prj_lumail"])
        XCTAssertEqual(result[0].servers.map(\.name), ["redis"])
        XCTAssertEqual(catalog[0].servers.map(\.name), ["dev", "redis"])
    }

    func testPortMatchFindsTheListeningServer() {
        let result = SidebarSearch.filterProjects(catalog, query: "3002")

        XCTAssertEqual(result.map(\.id), ["prj_lumail"])
        XCTAssertEqual(result[0].servers.map(\.id), ["srv_dev"])
    }

    func testLocalhostPortMatchIsEquivalentToThePortNumber() {
        let result = SidebarSearch.filterProjects(catalog, query: "localhost:8079")

        XCTAssertEqual(result[0].servers.map(\.name), ["redis"])
    }

    func testCommandMatchFindsTheServer() {
        let result = SidebarSearch.filterProjects(catalog, query: "next dev")

        XCTAssertEqual(result.map(\.id), ["prj_now"])
        XCTAssertEqual(result[0].servers.map(\.name), ["web"])
    }

    func testUnknownQueryReturnsNothing() {
        XCTAssertTrue(SidebarSearch.filterProjects(catalog, query: "codeline").isEmpty)
    }

    func testFirstMatchFollowsSidebarOrder() {
        XCTAssertEqual(SidebarSearch.firstMatch(projects: catalog, query: "now"), .server("srv_web"))
        XCTAssertEqual(SidebarSearch.firstMatch(projects: catalog, query: "redis"), .server("srv_redis"))
        XCTAssertNil(SidebarSearch.firstMatch(projects: catalog, query: "missing"))
        XCTAssertNil(SidebarSearch.firstMatch(projects: catalog, query: "  "))
    }

    func testSearchFieldLayoutsInAppKit() {
        let host = NSHostingView(rootView: SidebarSearchFieldHarness())
        host.frame = NSRect(x: 0, y: 0, width: 250, height: 52)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.height, 20)
        XCTAssertFalse(host.subviews.isEmpty)
    }
}

private struct SidebarSearchFieldHarness: View {
    @State private var text = "lumail"
    @FocusState private var focused: Bool

    var body: some View {
        SidebarSearchField(text: $text, focused: $focused, onSubmit: {})
            .frame(width: 250)
    }
}
