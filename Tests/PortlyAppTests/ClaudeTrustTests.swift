import Foundation
import XCTest
@testable import PortlyApp

final class ClaudeTrustTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func writeConfig(_ text: String, permissions: NSNumber = 0o600) throws -> URL {
        let file = directory.appendingPathComponent(".claude.json")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        return file
    }

    private func read(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    private func projects(in file: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return config["projects"] as? [String: Any] ?? [:]
    }

    private func isTrusted(_ root: String, in file: URL) throws -> Bool {
        let entry = try projects(in: file)[ClaudeTrust.projectKey(for: root)] as? [String: Any]
        return entry?["hasTrustDialogAccepted"] as? Bool == true
    }

    private var home: URL { directory.appendingPathComponent("home", isDirectory: true) }

    // MARK: - Approving

    func testApprovesAFolderThatHasNoEntryYet() throws {
        let file = try writeConfig("""
        {
          "numStartups": 12,
          "projects": {
            "/Users/dev/other": {
              "hasTrustDialogAccepted": true
            }
          }
        }
        """)

        let outcome = try ClaudeTrust.approve(root: "/Users/dev/app", file: file, home: home)

        XCTAssertEqual(outcome, .approved)
        XCTAssertTrue(try isTrusted("/Users/dev/app", in: file))
        XCTAssertTrue(try isTrusted("/Users/dev/other", in: file))
    }

    func testApprovesAFolderThatAlreadyHasAnEntry() throws {
        let file = try writeConfig("""
        {
          "projects": {
            "/Users/dev/app": {
              "lastCost": 2.8429284999999997,
              "lastSessionId": "abc"
            }
          }
        }
        """)

        XCTAssertEqual(try ClaudeTrust.approve(root: "/Users/dev/app", file: file, home: home), .approved)

        let entry = try XCTUnwrap(try projects(in: file)["/Users/dev/app"] as? [String: Any])
        XCTAssertEqual(entry["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(entry["lastSessionId"] as? String, "abc")
        XCTAssertTrue(try read(file).contains("2.8429284999999997"), "the untouched value must survive verbatim")
    }

    func testCreatesTheProjectsObjectWhenTheConfigHasNone() throws {
        let file = try writeConfig(#"{"numStartups": 3}"#)

        XCTAssertEqual(try ClaudeTrust.approve(root: "/Users/dev/app", file: file, home: home), .approved)
        XCTAssertTrue(try isTrusted("/Users/dev/app", in: file))
    }

    func testApprovesIntoAnEmptyProjectsObject() throws {
        let file = try writeConfig(#"{"projects": {}, "numStartups": 3}"#)

        XCTAssertEqual(try ClaudeTrust.approve(root: "/Users/dev/app", file: file, home: home), .approved)
        XCTAssertTrue(try isTrusted("/Users/dev/app", in: file))
    }

    func testLeavesTheFileAloneWhenTheFolderIsAlreadyTrusted() throws {
        let original = """
        {
          "projects": {
            "/Users/dev/app": {
              "hasTrustDialogAccepted": true
            }
          }
        }
        """
        let file = try writeConfig(original)

        XCTAssertEqual(try ClaudeTrust.approve(root: "/Users/dev/app", file: file, home: home), .alreadyApproved)
        XCTAssertEqual(try read(file), original)
    }

    func testSkipsTheHomeDirectoryBecauseClaudeCodeNeverPersistsIt() throws {
        let original = #"{"projects": {}}"#
        let file = try writeConfig(original)

        XCTAssertEqual(try ClaudeTrust.approve(root: home.path, file: file, home: home), .homeDirectory)
        XCTAssertEqual(try read(file), original)
    }

    func testReportsWhenClaudeCodeIsNotInstalled() throws {
        let missing = directory.appendingPathComponent("absent.json")

        XCTAssertEqual(try ClaudeTrust.approve(root: "/Users/dev/app", file: missing, home: home), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "Portly never creates the config itself")
    }

    func testRejectsAConfigThatIsNotAJSONObject() throws {
        let file = try writeConfig("[1, 2, 3]")

        XCTAssertThrowsError(try ClaudeTrust.approve(root: "/Users/dev/app", file: file, home: home))
    }

    func testApprovesSeveralRootsInOnePassAndCountsTheNewOnes() throws {
        let file = try writeConfig("""
        {
          "projects": {
            "/Users/dev/app": {
              "hasTrustDialogAccepted": true
            }
          }
        }
        """)

        let approved = try ClaudeTrust.approve(
            roots: ["/Users/dev/app", "/Users/dev/api", "/Users/dev/web", home.path],
            file: file,
            home: home
        )

        XCTAssertEqual(approved, 2)
        XCTAssertTrue(try isTrusted("/Users/dev/api", in: file))
        XCTAssertTrue(try isTrusted("/Users/dev/web", in: file))
        XCTAssertNil(try projects(in: file)[ClaudeTrust.projectKey(for: home.path)])
    }

    func testKeepsThePrivateFileMode() throws {
        let file = try writeConfig(#"{"projects": {}}"#, permissions: 0o600)

        _ = try ClaudeTrust.approve(root: "/Users/dev/app", file: file, home: home)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.int16Value, 0o600)
    }

    func testExpandsAndResolvesTheProjectKeyTheWayClaudeCodeDoes() throws {
        let real = directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(ClaudeTrust.projectKey(for: link.path), ClaudeTrust.projectKey(for: real.path))
        XCTAssertFalse(ClaudeTrust.projectKey(for: "~/app").hasPrefix("~"))
    }

    // MARK: - Config location

    func testFindsTheDefaultConfigFile() {
        let file = ClaudeTrust.globalConfigFile(environment: [:], home: home)

        XCTAssertEqual(file.path, home.appendingPathComponent(".claude.json").path)
    }

    func testHonoursClaudeConfigDir() {
        let file = ClaudeTrust.globalConfigFile(environment: ["CLAUDE_CONFIG_DIR": directory.path], home: home)

        XCTAssertEqual(file.path, directory.appendingPathComponent(".claude.json").path)
    }

    func testPrefersTheLegacyConfigFileWhenItExists() throws {
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let legacy = claudeDirectory.appendingPathComponent(".config.json")
        try "{}".write(to: legacy, atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeTrust.globalConfigFile(environment: [:], home: home).path, legacy.path)
    }
}

final class JSONObjectEditorTests: XCTestCase {
    private func insert(_ member: String, at path: [String], in text: String) throws -> String {
        let patched = try XCTUnwrap(JSONObjectEditor.inserting(member, atPath: path, in: Array(text.utf8)))
        return String(decoding: patched, as: UTF8.self)
    }

    func testInsertsAtTheRootAndKeepsTheIndentation() throws {
        let patched = try insert(#""added": true"#, at: [], in: """
        {
          "kept": 1
        }
        """)

        XCTAssertEqual(patched, """
        {
          "added": true,
          "kept": 1
        }
        """)
    }

    func testInsertsIntoAnEmptyObject() throws {
        XCTAssertEqual(try insert(#""added":true"#, at: [], in: "{}"), #"{"added":true}"#)
    }

    func testWalksNestedObjectsPastStringsAndArrays() throws {
        let patched = try insert(#""added":true"#, at: ["a", "b"], in: #"{"skip":["{",1],"quoted":"}\"","a":{"b":{"kept":1}}}"#)

        XCTAssertEqual(patched, #"{"skip":["{",1],"quoted":"}\"","a":{"b":{"added":true,"kept":1}}}"#)
    }

    func testLeavesEveryOtherByteAlone() throws {
        let patched = try insert(
            #""added":true"#,
            at: ["projects", "x"],
            in: #"{"floats":[0.1,1e-7,2.8429284999999997],"projects":{"x":{}}}"#
        )

        XCTAssertEqual(patched, #"{"floats":[0.1,1e-7,2.8429284999999997],"projects":{"x":{"added":true}}}"#)
    }

    func testReturnsNilWhenThePathIsMissingOrNotAnObject() {
        let bytes = Array(#"{"a":1,"b":{}}"#.utf8)

        XCTAssertNil(JSONObjectEditor.inserting(#""x":1"#, atPath: ["missing"], in: bytes))
        XCTAssertNil(JSONObjectEditor.inserting(#""x":1"#, atPath: ["a"], in: bytes))
        XCTAssertNil(JSONObjectEditor.inserting(#""x":1"#, atPath: [], in: Array("[1]".utf8)))
    }

    func testEscapesTheMemberNameAndKeepsSlashesReadable() throws {
        let member = try XCTUnwrap(JSONObjectEditor.member(name: #"/Users/dev/a"b"#, value: true))

        XCTAssertEqual(member, #""/Users/dev/a\"b":true"#)
    }
}
