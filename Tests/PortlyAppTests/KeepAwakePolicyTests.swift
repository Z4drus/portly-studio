import Foundation
import XCTest
@testable import PortlyApp

final class KeepAwakePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decide(
        holding: Bool,
        working: Bool,
        idleFor minutes: Double? = nil,
        offlineFor seconds: Double? = nil,
        lowBattery: Bool = false,
        idleMinutes: Int = 5
    ) -> KeepAwakePolicy.Decision {
        KeepAwakePolicy.decide(
            isHolding: holding,
            working: working,
            idleSince: minutes.map { now.addingTimeInterval(-$0 * 60) },
            idleMinutes: idleMinutes,
            offlineSince: seconds.map { now.addingTimeInterval(-$0) },
            lowBattery: lowBattery,
            now: now
        )
    }

    func testAWorkingAgentStartsTheHold() {
        XCTAssertEqual(decide(holding: false, working: true), .hold)
        XCTAssertEqual(decide(holding: true, working: true), .keep)
    }

    func testTheHoldOutlastsShortPausesThenReleases() {
        XCTAssertEqual(decide(holding: true, working: false, idleFor: 4.9), .keep)
        XCTAssertEqual(decide(holding: true, working: false, idleFor: 5), .release(.agentsIdle))
    }

    func testReleasedStaysArmedUntilAnAgentWorksAgain() {
        XCTAssertEqual(decide(holding: false, working: false, idleFor: 30), .keep)
        XCTAssertEqual(decide(holding: false, working: true), .hold, "armed: work after a release holds again")
    }

    func testLowBatteryAndALostNetworkWinOverWork() {
        XCTAssertEqual(decide(holding: true, working: true, lowBattery: true), .release(.lowBattery))
        XCTAssertEqual(decide(holding: false, working: true, lowBattery: true), .keep)
        XCTAssertEqual(decide(holding: true, working: true, offlineFor: 89), .keep)
        XCTAssertEqual(decide(holding: true, working: true, offlineFor: 90), .release(.offline))
        XCTAssertEqual(decide(holding: false, working: true, offlineFor: 120), .keep)
    }

    private func screen(
        lidClosed: Bool = true,
        awake: Bool = true,
        external: Bool = false,
        lit: Bool = true,
        dimmed: Bool = false,
        askedAgo seconds: Double? = nil
    ) -> KeepAwakePolicy.ScreenAction {
        KeepAwakePolicy.screenAction(
            lidClosed: lidClosed,
            keepingMacAwake: awake,
            externalDisplay: external,
            builtInLit: lit,
            dimmed: dimmed,
            lastSleepRequest: seconds.map { now.addingTimeInterval(-$0) },
            now: now
        )
    }

    func testALitScreenBehindAClosedLidIsPutToSleepThenDimmed() {
        XCTAssertEqual(screen(), .sleepScreen)
        XCTAssertEqual(screen(askedAgo: 5), .none, "give it a moment to go dark")
        XCTAssertEqual(screen(askedAgo: 10), .dimAndSleepScreen)
        XCTAssertEqual(screen(dimmed: true, askedAgo: 15), .none)
        XCTAssertEqual(screen(dimmed: true, askedAgo: 30), .sleepScreen, "keeps asking while it stays lit")
        XCTAssertEqual(screen(lit: false, askedAgo: 60), .none)
    }

    func testTheScreenIsLeftAloneWhenTheMacIsInUseOrNotKeptAwake() {
        XCTAssertEqual(screen(lidClosed: false), .none)
        XCTAssertEqual(screen(external: true), .none, "clamshell mode with another screen")
        XCTAssertEqual(screen(awake: false), .none, "macOS sleeps on its own")
    }

    func testOpeningTheLidGivesTheBrightnessBack() {
        XCTAssertEqual(screen(lidClosed: false, dimmed: true), .restoreBrightness)
        XCTAssertEqual(screen(lidClosed: false, lit: false, dimmed: true), .restoreBrightness)
    }
}
