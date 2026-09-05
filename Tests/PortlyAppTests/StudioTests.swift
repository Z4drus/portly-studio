import Foundation
import PortlyCore
import XCTest
@testable import PortlyApp

final class PaneLayoutTests: XCTestCase {
    private func pane(_ id: String) -> TerminalPaneConfig {
        TerminalPaneConfig(id: id, kind: .shell)
    }

    func testSplitAddsASiblingNextToTheTarget() {
        let layout = PaneLayout.leaf(pane("a"))
            .splitting("a", axis: .horizontal, adding: pane("b"))
        XCTAssertEqual(layout.paneIDs, ["a", "b"])
        guard case .split(_, let axis, let ratio, _, _) = layout else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(ratio, 0.5)
    }

    func testRemovingCollapsesASingleChildSplit() {
        let layout = PaneLayout.leaf(pane("a"))
            .splitting("a", axis: .horizontal, adding: pane("b"))
            .splitting("b", axis: .vertical, adding: pane("c"))
        XCTAssertEqual(layout.paneIDs, ["a", "b", "c"])

        let withoutB = layout.removing("b")
        XCTAssertEqual(withoutB?.paneIDs, ["a", "c"])

        let onlyA = withoutB?.removing("c")
        guard case .leaf(let remaining)? = onlyA else {
            return XCTFail("expected the tree to collapse to a leaf")
        }
        XCTAssertEqual(remaining.id, "a")
        XCTAssertNil(onlyA?.removing("a"))
    }

    func testRatioUpdateTargetsOneSplit() {
        let layout = PaneLayout.leaf(pane("a"))
            .splitting("a", axis: .horizontal, adding: pane("b"))
        guard case .split(let id, _, _, _, _) = layout else { return XCTFail() }
        let updated = layout.updatingRatio(splitID: id, ratio: 0.3)
        guard case .split(_, _, let ratio, _, _) = updated else { return XCTFail() }
        XCTAssertEqual(ratio, 0.3)
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let layout = PaneLayout.leaf(pane("a"))
            .splitting("a", axis: .vertical, adding: pane("b"))
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(PaneLayout.self, from: data)
        XCTAssertEqual(decoded, layout)
    }

    func testAgentPresetsResolveCommands() {
        XCTAssertEqual(AgentPreset.claudeBypass.command(custom: ""), "claude --dangerously-skip-permissions")
        XCTAssertNil(AgentPreset.shell.command(custom: "anything"))
        XCTAssertNil(AgentPreset.custom.command(custom: "   "))
        XCTAssertEqual(AgentPreset.custom.command(custom: " aider "), "aider")
    }
}

final class TerminalEnvironmentTests: XCTestCase {
    func testInheritedAgentMarkersAreDropped() {
        let env = TerminalStyling.sanitized([
            "PATH": "/usr/bin",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDECODE": "1",
            "CODEX_SANDBOX": "1",
            "TERM_SESSION_ID": "x",
            "HOME": "/Users/x",
        ])
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME"])
    }
}

final class IconCatalogTests: XCTestCase {
    func testCatalogLoadsTheWholeSet() {
        XCTAssertGreaterThan(IconCatalog.shared.icons.count, 3000)
        XCTAssertNotNil(IconCatalog.shared.icon("design-development/code"))
        XCTAssertNotNil(IconImageCache.image(for: "design-development/code"))
    }

    func testEveryAppIconExists() {
        let missing = AppIcon.allCases.filter { !IconCatalog.shared.contains($0.rawValue) }
        XCTAssertEqual(missing.map(\.rawValue), [])
        let legacyMissing = LegacyProjectIcons.map.values.filter { !IconCatalog.shared.contains($0) }
        XCTAssertEqual(legacyMissing, [])
    }

    func testSearchRanksExactNamesFirstAndSpeaksFrench() {
        XCTAssertEqual(IconCatalog.shared.search("code").first?.id, "design-development/code")
        let french = IconCatalog.shared.search("développeur")
        XCTAssertTrue(french.contains { $0.id == "design-development/code" })
        let folded = IconCatalog.shared.search("developpeur")
        XCTAssertEqual(folded.map(\.id), french.map(\.id))
        XCTAssertTrue(IconCatalog.shared.search("dossier").contains { $0.id == "files/folder" })
        XCTAssertTrue(IconCatalog.shared.search("zzzz-nothing").isEmpty)
    }
}

final class EnvFileTests: XCTestCase {
    func testScanFindsOnlyEnvFilesAtRootInAStableOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portly-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [".env.example", ".env.local", ".env", ".environment", "env", "README.md"] {
            try "".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".env.d"), withIntermediateDirectories: true)

        let names = EnvFile.scan(root: root.path).map(\.name)
        XCTAssertEqual(names, [".env", ".env.local", ".env.example"])
    }

    func testDropCopiesWithUniqueNamesAndSkipsFilesAlreadyInside() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portly-drop-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("portly-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = outside.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: source)
        try Data([9]).write(to: root.appendingPathComponent("photo.png"))
        let inside = root.appendingPathComponent("inside.txt")
        try "x".write(to: inside, atomically: true, encoding: .utf8)

        let outcome = ProjectFileDrop.copy(urls: [source, inside], toRoot: root.path)
        XCTAssertEqual(outcome.copied, ["photo-2.png"])
        XCTAssertEqual(outcome.skipped, ["inside.txt"])
        XCTAssertEqual(outcome.failed, [])
        XCTAssertTrue(ProjectFileDrop.agentMessage(for: outcome.copied).contains("photo-2.png"))
    }
}

final class DependencyInspectorTests: XCTestCase {
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portly-deps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testNoPackageJSONMeansNothingToGate() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(DependencyInspector.inspect(workingDirectory: root.path, projectRoot: root.path))
    }

    func testDetectsManagerFromLockfileAndMissingModules() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("bun.lock"), atomically: true, encoding: .utf8)

        let status = try XCTUnwrap(DependencyInspector.inspect(workingDirectory: root.path, projectRoot: root.path))
        XCTAssertEqual(status.manager, .bun)
        XCTAssertFalse(status.installed)
        XCTAssertEqual(status.manager.installCommand, "bun install")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/.bin"), withIntermediateDirectories: true)
        XCTAssertFalse(try XCTUnwrap(DependencyInspector.inspect(workingDirectory: root.path, projectRoot: root.path)).installed)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/react"), withIntermediateDirectories: true)
        XCTAssertTrue(try XCTUnwrap(DependencyInspector.inspect(workingDirectory: root.path, projectRoot: root.path)).installed)
    }

    func testWorkspacePackageInheritsRootModulesAndLockfile() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "{}".write(to: app.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/next"), withIntermediateDirectories: true)

        let status = try XCTUnwrap(DependencyInspector.inspect(workingDirectory: app.path, projectRoot: root.path))
        XCTAssertEqual(status.manager, .pnpm)
        XCTAssertTrue(status.installed)
        XCTAssertEqual(status.packageDirectory, app.path)
    }

    func testPackageManagerFieldWins() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"packageManager":"yarn@4.1.0"}"#.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DependencyInspector.inspect(workingDirectory: root.path, projectRoot: root.path)?.manager, .yarn)
    }
}

final class EnvHighlighterTests: XCTestCase {
    private func tokens(_ text: String) -> [EnvHighlighter.Token] {
        EnvHighlighter.spans(in: text).map(\.token)
    }

    func testTokenisesKeysValuesAndComments() {
        XCTAssertEqual(tokens("# hello"), [.comment])
        XCTAssertEqual(tokens("API_KEY=abc"), [.key, .punctuation, .value])
        XCTAssertEqual(tokens("NAME=\"quoted\""), [.key, .punctuation, .string])
        XCTAssertEqual(tokens("export PORT=3000"), [.keyword, .key, .punctuation, .value])
        XCTAssertEqual(tokens("URL=http://x # trailing"), [.key, .punctuation, .value, .comment])
        XCTAssertEqual(tokens("A=${B}/path"), [.key, .punctuation, .value, .interpolation])
    }

    func testFlagsUnclosedQuotesAndBrokenLines() {
        XCTAssertEqual(tokens("SECRET=\"oops"), [.key, .punctuation, .error])
        XCTAssertEqual(tokens("NAME=\"ok\" junk"), [.key, .punctuation, .string, .error])
        XCTAssertEqual(tokens("just words"), [.error])
        XCTAssertEqual(tokens("9BAD=1"), [.error, .punctuation, .value])
    }

    func testRangesLineUpWithTheSource() {
        let text = "A=1\nB=\"two\""
        let spans = EnvHighlighter.spans(in: text)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: spans[0].range), "A")
        XCTAssertEqual(ns.substring(with: spans[3].range), "B")
        XCTAssertEqual(ns.substring(with: spans[5].range), "\"two\"")
    }
}

final class PortFallbackTests: XCTestCase {
    func testNextFreePortSkipsListenersAndReservedPorts() {
        let busy: Set<Int> = [3001, 3002]
        let next = ServerRuntime.nextFreePort(after: 3000, reserved: [3003]) { busy.contains($0) }
        XCTAssertEqual(next, 3004)
        XCTAssertNil(ServerRuntime.nextFreePort(after: 65_535, reserved: []) { _ in false })
    }

    func testRewritingPortTouchesOnlyExplicitPortFlags() {
        XCTAssertEqual(ServerRuntime.rewritingPort(in: "next dev -p 3000", from: 3000, to: 3001), "next dev -p 3001")
        XCTAssertEqual(ServerRuntime.rewritingPort(in: "vite --port=3000 --host", from: 3000, to: 3002), "vite --port=3002 --host")
        XCTAssertEqual(ServerRuntime.rewritingPort(in: "PORT=3000 bun run dev", from: 3000, to: 3001), "PORT=3001 bun run dev")
        XCTAssertEqual(ServerRuntime.rewritingPort(in: "pnpm dev", from: 3000, to: 3001), "pnpm dev")
        XCTAssertEqual(ServerRuntime.rewritingPort(in: "serve -p 30000", from: 3000, to: 3001), "serve -p 30000")
        XCTAssertEqual(ServerRuntime.rewritingPort(in: "open http://localhost:3000/admin", from: 3000, to: 3001), "open http://localhost:3001/admin")
    }

    func testConfigDefaultsAutoPortOnForOlderFiles() throws {
        let json = #"{"projects":[]}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(PortlyConfig.self, from: json)
        XCTAssertTrue(config.autoSelectFreePort)
    }
}

final class PaneTitleTests: XCTestCase {
    func testSpinnerGlyphsAreStripped() {
        XCTAssertEqual(TerminalPaneRuntime.cleanTitle("✳ Fixing the sidebar"), "Fixing the sidebar")
        XCTAssertEqual(TerminalPaneRuntime.cleanTitle("⠋ ✶  Refactor auth"), "Refactor auth")
        XCTAssertEqual(TerminalPaneRuntime.cleanTitle("Claude Code"), "Claude Code")
        XCTAssertEqual(TerminalPaneRuntime.cleanTitle("  zsh  "), "zsh")
        XCTAssertEqual(TerminalPaneRuntime.cleanTitle("✳ ✶"), "✳ ✶")
        XCTAssertEqual(TerminalPaneRuntime.cleanTitle("[web] build"), "web] build")
    }
}

final class ClaudeTranscriptTests: XCTestCase {
    func testEncodedDirectoryMatchesClaudeLayout() {
        XCTAssertEqual(
            ClaudeTranscripts.encodedDirectoryName(forProjectRoot: "/Users/noe/Documents/app"),
            "-Users-noe-Documents-app"
        )
    }

    func testLaunchCommandResumesOnlyWhenATranscriptExists() {
        let base = "claude --dangerously-skip-permissions"
        XCTAssertEqual(
            ClaudeTranscripts.launchCommand(base: base, sessionID: "abc", hasTranscript: false),
            "claude --dangerously-skip-permissions --session-id abc"
        )
        XCTAssertEqual(
            ClaudeTranscripts.launchCommand(base: base, sessionID: "abc", hasTranscript: true),
            "claude --dangerously-skip-permissions --resume abc"
        )
        XCTAssertEqual(ClaudeTranscripts.launchCommand(base: "codex", sessionID: "abc", hasTranscript: true), "codex")
        XCTAssertEqual(ClaudeTranscripts.launchCommand(base: base, sessionID: nil, hasTranscript: true), base)
    }

    func testPaneConfigWithoutSessionIDStillDecodes() throws {
        let json = #"{"id":"pane_1","kind":"agent","launchCommand":"claude"}"#.data(using: .utf8)!
        let pane = try JSONDecoder().decode(TerminalPaneConfig.self, from: json)
        XCTAssertNil(pane.agentSessionID)
        XCTAssertEqual(pane.kind, .agent)
    }
}

final class LoginEnvironmentTests: XCTestCase {
    func testMergedPathKeepsShellOrderAndDeduplicates() {
        let merged = LoginEnvironment.merged(shellPath: "/opt/homebrew/bin:/usr/bin:/custom", home: "/Users/x")
        let parts = merged.split(separator: ":").map(String.init)
        XCTAssertEqual(Array(parts.prefix(3)), ["/opt/homebrew/bin", "/usr/bin", "/custom"])
        XCTAssertEqual(parts.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertTrue(parts.contains("/Users/x/Library/pnpm"))
        XCTAssertTrue(parts.contains("/sbin"))
    }

    func testShellPathIsResolvedFromTheLoginShell() {
        let path = LoginEnvironment.queryShellPath(timeout: 10)
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.contains("/usr/bin") ?? false)
    }
}

final class LoginEnvironmentStabilityTests: XCTestCase {
    func testMultishellEntriesResolveToTheirInstallation() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("portly-fnm-\(UUID().uuidString)")
        let installation = base.appendingPathComponent("node-versions/v22/installation/bin")
        let multishell = base.appendingPathComponent("fnm_multishells/123_456")
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: multishell.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: multishell, withDestinationURL: installation.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: base) }

        let stable = LoginEnvironment.stabilised(multishell.appendingPathComponent("bin").path)
        XCTAssertEqual(URL(fileURLWithPath: stable).resolvingSymlinksInPath().path, installation.resolvingSymlinksInPath().path)
        XCTAssertFalse(stable.contains("fnm_multishells"))
        XCTAssertEqual(LoginEnvironment.stabilised("/usr/bin"), "/usr/bin")
    }
}
