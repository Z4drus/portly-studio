import Foundation
import XCTest
@testable import PortlyApp

final class PortArgumentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portly-port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(scripts: [String: String], lockfile: String? = nil) throws {
        let json = try JSONSerialization.data(withJSONObject: ["name": "app", "scripts": scripts])
        try json.write(to: directory.appendingPathComponent("package.json"))
        if let lockfile {
            try Data().write(to: directory.appendingPathComponent(lockfile))
        }
    }

    func testRecognisesOnlyBarePackageScripts() {
        XCTAssertEqual(ScriptInvocation("pnpm run dev")?.script, "dev")
        XCTAssertEqual(ScriptInvocation("npm run dev")?.manager, "npm")
        XCTAssertEqual(ScriptInvocation("bun run dev")?.manager, "bun")
        XCTAssertEqual(ScriptInvocation("yarn dev")?.script, "dev")
        XCTAssertEqual(ScriptInvocation("pnpm dev")?.script, "dev")
        XCTAssertNil(ScriptInvocation("bun dev"), "bun <name> may be a file, not a script")
        XCTAssertNil(ScriptInvocation("pnpm run dev --port 3000"))
        XCTAssertNil(ScriptInvocation("next dev"))
        XCTAssertNil(ScriptInvocation("pnpm --filter web dev"))
    }

    func testNpmNeedsTheSeparatorTheOthersDoNot() {
        XCTAssertEqual(ScriptInvocation("npm run dev")?.appending(["--port", "5190"]), "npm run dev -- --port 5190")
        XCTAssertEqual(ScriptInvocation("pnpm run dev")?.appending(["--port", "5190"]), "pnpm run dev --port 5190")
        XCTAssertEqual(ScriptInvocation("bun run dev")?.appending(["--port", "5190"]), "bun run dev --port 5190")
    }

    func testToolsThatIgnorePortGetTheFlag() {
        XCTAssertTrue(PortArgument.needsPortFlag(script: "vite"))
        XCTAssertTrue(PortArgument.needsPortFlag(script: "vite dev --host"))
        XCTAssertTrue(PortArgument.needsPortFlag(script: "cross-env NODE_ENV=development vite"))
        XCTAssertTrue(PortArgument.needsPortFlag(script: "astro dev"))
        XCTAssertTrue(PortArgument.needsPortFlag(script: "ng serve"))
        XCTAssertTrue(PortArgument.needsPortFlag(script: "react-router dev"))
        XCTAssertTrue(PortArgument.needsPortFlag(script: "vite preview"))
    }

    func testOptionValuesAreNotMistakenForSubcommands() {
        XCTAssertTrue(PortArgument.needsPortFlag(script: "vite --host 0.0.0.0"))
        XCTAssertTrue(PortArgument.needsPortFlag(script: "vite --mode staging --config vite.dev.ts"))
        XCTAssertTrue(PortArgument.needsPortFlag(script: "astro --root site dev"))
        XCTAssertFalse(PortArgument.needsPortFlag(script: "vite --mode production build"))
    }

    func testToolsThatReadPortOrNameOneAreLeftAlone() {
        XCTAssertFalse(PortArgument.needsPortFlag(script: "next dev --turbopack"))
        XCTAssertFalse(PortArgument.needsPortFlag(script: "nuxt dev"))
        XCTAssertFalse(PortArgument.needsPortFlag(script: "vite --port 4000"))
        XCTAssertFalse(PortArgument.needsPortFlag(script: "vite -p 4000"))
        XCTAssertFalse(PortArgument.needsPortFlag(script: "vite build"))
        XCTAssertFalse(PortArgument.needsPortFlag(script: "prisma generate && vite"))
    }

    func testLaunchCommandReadsTheScriptFromPackageJson() throws {
        try write(scripts: ["dev": "vite", "web": "next dev"])
        let dir = directory.path
        XCTAssertEqual(PortArgument.launchCommand(for: "pnpm run dev", port: 5190, directory: dir), "pnpm run dev --port 5190")
        XCTAssertEqual(PortArgument.launchCommand(for: "npm run dev", port: 5190, directory: dir), "npm run dev -- --port 5190")
        XCTAssertEqual(PortArgument.launchCommand(for: "pnpm run web", port: 3000, directory: dir), "pnpm run web")
        XCTAssertEqual(PortArgument.launchCommand(for: "pnpm run dev", port: nil, directory: dir), "pnpm run dev")
        XCTAssertEqual(PortArgument.launchCommand(for: "pnpm run missing", port: 3000, directory: dir), "pnpm run missing")
    }

    func testDetectedCommandsArePlainScriptsWhateverThePort() throws {
        try write(scripts: ["dev": "vite", "build": "vite build"], lockfile: "pnpm-lock.yaml")
        // Every port is taken: the suggestion moves the port, never the command.
        let suggestions = CommandDetector.suggestions(inProjectRoot: directory.path, reservedPorts: Set(5173...5180))
        let dev = try XCTUnwrap(suggestions.first { $0.name == "dev" })
        XCTAssertEqual(dev.command, "pnpm run dev")
        XCTAssertNotEqual(dev.port, 5173)
    }

    func testDetectionUsesTheLockfilesPackageManager() throws {
        try write(scripts: ["dev": "next dev"], lockfile: "bun.lock")
        let suggestions = CommandDetector.suggestions(inProjectRoot: directory.path)
        XCTAssertEqual(suggestions.first?.command, "bun run dev")
    }
}
