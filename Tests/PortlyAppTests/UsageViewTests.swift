import AppKit
import SwiftUI
@testable import PortlyApp
import XCTest

/// Hosts the usage views in AppKit so a layout that throws or lays out to
/// nothing is caught here rather than at launch.
@MainActor
final class UsageViewTests: XCTestCase {
    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private var claude: ProviderSnapshot {
        ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "session", label: "Current session", usedFraction: 0.42, resetsAt: now.addingTimeInterval(51 * 60)),
                LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.17, resetsAt: now.addingTimeInterval(3 * 86_400)),
                LimitWindow(id: "weekly_fable", label: "Fable", usedFraction: 0.61, resetsAt: now.addingTimeInterval(3 * 86_400)),
            ],
            headlineID: "session"
        )
    }

    private var codex: ProviderSnapshot {
        ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official,
            status: .needsAuth, windows: []
        )
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testProviderCellAndTooltipLayOut() {
        let cell = host(ProviderCell(snapshot: claude, activity: nil, isRefreshing: false), width: 80, height: 120)
        XCTAssertGreaterThan(cell.fittingSize.height, NotchLayout.ringDiameter)

        let sessions = [AgentSession(id: "claude.1", name: "portly-studio", detail: "Terminal · portly-studio",
                                     state: .busy, waitingFor: nil, since: now)]
        let card = host(
            TooltipCard(snapshot: claude, activity: ActivitySummary(sessions: sessions), now: now),
            width: NotchLayout.cardWidth + NotchLayout.tailLength, height: 600
        )
        XCTAssertEqual(card.fittingSize.width, NotchLayout.cardWidth + NotchLayout.tailLength, accuracy: 1)
        let expected = NotchLayout.cardHeight(windowCount: 3, sessionCount: 1)
        XCTAssertEqual(card.fittingSize.height, expected, accuracy: 1)

        let empty = host(TooltipCard(snapshot: codex, now: now), width: 400, height: 300)
        XCTAssertGreaterThan(empty.fittingSize.height, 0)
    }

    func testNotchRootViewLaysOutForEveryEdge() {
        for edge in NotchEdge.allCases {
            let model = NotchViewModel()
            model.edge = edge
            model.snapshots = [claude, codex]
            model.isExpanded = true
            model.hoveredIndex = 0
            let size = model.panelSize
            let view = host(NotchRootView(model: model), width: size.width, height: size.height)
            XCTAssertEqual(view.frame.size, size, "the \(edge.rawValue) panel did not keep its size")
            XCTAssertGreaterThan(model.shapeLength, 0)
            XCTAssertGreaterThan(model.notchDepth, 0)
            XCTAssertTrue(model.placement.rect(along: 0, across: 0, length: 10, depth: 10).width > 0)
        }
    }

    func testSidebarSectionRendersCollapsedAndExpanded() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "usage.sidebarExpanded")
        defer { defaults.set(previous, forKey: "usage.sidebarExpanded") }

        defaults.set(false, forKey: "usage.sidebarExpanded")
        let collapsed = host(UsageSidebarSection().frame(width: 250), width: 250, height: 60)
        XCTAssertEqual(collapsed.fittingSize.height, 32, accuracy: 1)

        defaults.set(true, forKey: "usage.sidebarExpanded")
        let expanded = host(UsageSidebarSection().frame(width: 250), width: 250, height: 400)
        XCTAssertGreaterThan(expanded.fittingSize.height, 32)
    }

    /// The settings screen is deliberately not hosted here: listing the
    /// accounts reads the real keychain, which a test must never do.
    func testMiniRingKeepsItsSize() {
        let ring = host(MiniUsageRing(snapshot: claude, size: 15), width: 20, height: 20)
        XCTAssertEqual(ring.fittingSize.width, 15, accuracy: 0.5)
        XCTAssertEqual(ring.fittingSize.height, 15, accuracy: 0.5)
    }
}
