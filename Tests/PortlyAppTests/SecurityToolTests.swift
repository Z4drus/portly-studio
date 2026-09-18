import AppKit
import Foundation
import XCTest
@testable import PortlyApp

final class SecurityToolTests: XCTestCase {
    func testTheSecretIsAskedForTheWayClaudeCodeAsks() {
        XCTAssertEqual(
            SecurityTool.arguments(service: "Claude Code-credentials", account: "me"),
            ["find-generic-password", "-s", "Claude Code-credentials", "-a", "me", "-w"]
        )
        XCTAssertEqual(
            SecurityTool.arguments(service: "Claude Code-credentials", account: nil),
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
    }

    func testExitStatusesBecomeTheRightRingState() {
        guard case .needsAuth = SecurityTool.error(forExitStatus: 44) else { return XCTFail("44 is not found") }
        guard case .credentialExpired = SecurityTool.error(forExitStatus: 36) else {
            return XCTFail("36 is a Mac not ready to answer, not a refusal")
        }
        guard case .credentialExpired = SecurityTool.error(forExitStatus: -1) else {
            return XCTFail("a timeout says nothing about the account")
        }
        guard case .accessDenied = SecurityTool.error(forExitStatus: 1) else { return XCTFail("anything else is a refusal") }
    }

    func testCredentialsDecodeFromPlainAndHexOutput() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1800000000000,"subscriptionType":"max"},"mcpOAuth":{}}"#
        let plain = try ClaudeCredentials.decode(Data(json.utf8))
        XCTAssertEqual(plain.accessToken, "tok")
        XCTAssertEqual(plain.subscriptionType, "max")
        XCTAssertEqual(plain.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))

        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ClaudeCredentials.decode(Data(hex.utf8)).accessToken, "tok")

        XCTAssertEqual(SecurityTool.trimmingNewline(Data("abc\n".utf8)), Data("abc".utf8))
        XCTAssertNil(SecurityTool.dataFromHex(Data("not hex".utf8)))
        XCTAssertThrowsError(try ClaudeCredentials.decode(Data("{}".utf8)))
    }

    /// `{ } [ ] @ | ~ #` live on the Option layer of most non-US layouts.
    func testOptionComposesCharactersAndStaysMetaForEditingKeys() {
        let option: NSEvent.ModifierFlags = [.option]
        XCTAssertFalse(TerminalOptionKey.actsAsMeta(keyCode: 5, modifiers: option), "⌥G is @ on a Swiss layout")
        XCTAssertFalse(TerminalOptionKey.actsAsMeta(keyCode: 26, modifiers: option))
        XCTAssertTrue(TerminalOptionKey.actsAsMeta(keyCode: 123, modifiers: option), "⌥← still jumps a word")
        XCTAssertTrue(TerminalOptionKey.actsAsMeta(keyCode: 51, modifiers: option), "⌥⌫ still deletes a word")
        XCTAssertFalse(TerminalOptionKey.actsAsMeta(keyCode: 123, modifiers: []))
    }

    @MainActor
    func testALostFoldIsCaughtByTheNextPoll() {
        let left = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(NotchWindowController.foldIsOverdue(outsideSince: left, now: left.addingTimeInterval(0.5), grace: 0.45))
        XCTAssertTrue(NotchWindowController.foldIsOverdue(outsideSince: left, now: left.addingTimeInterval(0.95), grace: 0.45))
    }
}
