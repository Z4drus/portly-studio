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

    /// Older apps answer without `temporaryJobs` (and some with a retired
    /// `temporaryServers` array); the CLI keeps decoding their status.
    func testPortlyStatusDecodesOlderPayloads() throws {
        let payload = Data(#"{"version":"0.1.10","apiPort":7737,"projects":[],"temporaryServers":[]}"#.utf8)

        let status = try PortlyAPI.decoder().decode(PortlyStatus.self, from: payload)

        XCTAssertTrue(status.projects.isEmpty)
        XCTAssertTrue(status.temporaryJobs.isEmpty)
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
        XCTAssertTrue(updated.contains("portly temp '<command>'"))
        XCTAssertTrue(updated.contains("portly wait \"$job_id\""))
        XCTAssertTrue(updated.contains("exits with code `124`"))
        XCTAssertFalse(updated.contains("old rule"))
        XCTAssertEqual(updated.components(separatedBy: "portly:managed-rule:start").count - 1, 1)
    }

    func testTemporaryTimeoutParsesFriendlyDurations() {
        XCTAssertEqual(TemporaryTimeout.parse("45"), 45)
        XCTAssertEqual(TemporaryTimeout.parse("30s"), 30)
        XCTAssertEqual(TemporaryTimeout.parse("1.5m"), 90)
        XCTAssertEqual(TemporaryTimeout.parse("2h"), 7_200)
        XCTAssertNil(TemporaryTimeout.parse("0"))
        XCTAssertNil(TemporaryTimeout.parse("forever"))
        XCTAssertNil(TemporaryTimeout.parse("8d"))
        XCTAssertEqual(TemporaryTimeout.display(90), "90s")
        XCTAssertEqual(TemporaryTimeout.display(1_800), "30m")
        XCTAssertEqual(TemporaryTimeout.display(7_200), "2h")
    }

    func testTemporaryJobMapsItsOutcomeToAShellExitCode() throws {
        // Whole seconds: the wire format is ISO 8601 without fractions.
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let base = TemporaryJobStatus(
            id: "tmp_test", name: "build", command: "pnpm run build", directory: "/tmp",
            state: .succeeded, pid: nil, startedAt: moment, finishedAt: moment.addingTimeInterval(12),
            timeoutSeconds: 60, deadline: moment.addingTimeInterval(60), exitCode: 0, error: nil
        )
        XCTAssertEqual(base.elapsedSeconds, 12)
        XCTAssertEqual(base.processExitCode, 0)

        var failed = base
        failed.state = .failed
        failed.exitCode = 7
        XCTAssertEqual(failed.processExitCode, 7)

        var timedOut = base
        timedOut.state = .timedOut
        timedOut.exitCode = nil
        XCTAssertEqual(timedOut.processExitCode, 124)

        var stopped = base
        stopped.state = .stopped
        XCTAssertEqual(stopped.processExitCode, 130)
        XCTAssertTrue(stopped.state.isFinished)
        XCTAssertFalse(TemporaryJobState.running.isFinished)

        // The wire format round-trips, port and URL included.
        var preview = base
        preview.port = 4173
        preview.url = "http://localhost:4173"
        let decoded = try PortlyAPI.decoder().decode(TemporaryJobStatus.self, from: PortlyAPI.encoder().encode(preview))
        XCTAssertEqual(decoded, preview)
    }

    func testRawWaitStatusIsNormalizedBeforeExposingExitCode() {
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(0), 0)
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(7 << 8), 7)
        XCTAssertEqual(ServerRuntime.normalizedProcessExitCode(15), 143)
        XCTAssertNil(ServerRuntime.normalizedProcessExitCode(nil))
    }
}
