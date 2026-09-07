@testable import PortlyApp
import PortlyCore
import XCTest

@MainActor
final class CoreModelTests: XCTestCase {
    func testServerConfigDecodesOlderPayloadWithoutActions() throws {
        let payload = Data(#"{"name":"web","command":"pnpm dev"}"#.utf8)

        let server = try PortlyAPI.decoder().decode(ServerConfig.self, from: payload)

        XCTAssertTrue(server.actions.isEmpty)
    }

    func testServerActionsRoundTripThroughConfig() throws {
        let server = ServerConfig(
            name: "web",
            command: "pnpm dev",
            actions: [ServerAction(name: "clear-cache", command: "trash .next/cache")]
        )

        let data = try PortlyAPI.encoder().encode(server)
        let decoded = try PortlyAPI.decoder().decode(ServerConfig.self, from: data)

        XCTAssertEqual(decoded.actions, server.actions)
    }

    /// Older apps still answer with a `temporaryServers` array; the CLI must
    /// keep decoding their status rather than refusing to talk to them.
    func testPortlyStatusIgnoresRetiredTemporaryServers() throws {
        let payload = Data(#"{"version":"0.1.10","apiPort":7737,"projects":[],"temporaryServers":[]}"#.utf8)

        let status = try PortlyAPI.decoder().decode(PortlyStatus.self, from: payload)

        XCTAssertTrue(status.projects.isEmpty)
        XCTAssertEqual(status.apiPort, 7737)
    }

    func testManagedRuleUpgradeReplacesOldBlockAndPreservesSurroundings() {
        let old = """
        Before
        <!-- portly:managed-rule:start -->
        old rule
        <!-- portly:managed-rule:end -->
        After
        """

        let updated = AgentSetup.installManagedRule(in: old)

        XCTAssertTrue(updated.contains("Before"))
        XCTAssertTrue(updated.contains("After"))
        XCTAssertTrue(updated.contains("run it directly in the foreground"))
        XCTAssertFalse(updated.contains("portly temp"))
        XCTAssertFalse(updated.contains("old rule"))
        XCTAssertEqual(updated.components(separatedBy: "portly:managed-rule:start").count - 1, 1)
    }

    func testRawWaitStatusIsNormalizedBeforeExposingExitCode() {
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(0), 0)
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(7 << 8), 7)
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(15), 143)
        XCTAssertNil(ServerRuntime.normalizedProcessExitCode(nil))
    }
}
