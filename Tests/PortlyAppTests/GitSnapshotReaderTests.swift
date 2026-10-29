import Foundation
import XCTest
@testable import PortlyApp

/// Reads a real, throwaway repository end to end: the `git` binary, the
/// porcelain output, the line counts and the history.
final class GitSnapshotReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(GitCommand.executable == nil, "git is not installed")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portly-git-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "tests@example.com"])
        git(["config", "user.name", "Tests"])
        git(["config", "commit.gpgsign", "false"])
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func git(_ arguments: [String]) -> GitCommand.Result? {
        GitCommand.run(arguments, in: root.path)
    }

    private func write(_ name: String, _ content: String) throws {
        try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testAFolderWithoutGitIsNotARepository() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("portly-plain-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        // A temp folder may itself live inside a repository on some machines.
        if GitSnapshotReader.repositoryRoot(for: FileManager.default.temporaryDirectory.path) == nil {
            XCTAssertNil(GitSnapshotReader.repositoryRoot(for: plain.path))
        }
    }

    func testSnapshotReflectsCommitsChangesAndIgnoredEnvFiles() throws {
        try write("README.md", "one\ntwo\n")
        try write(".gitignore", ".env\n")
        git(["add", "."])
        git(["commit", "-q", "-m", "initial"])
        try write("README.md", "one\nthree\nfour\n")
        try write("notes.txt", "a\nb\nc\n")
        try write(".env", "SECRET=1\n")

        let repository = GitSnapshotReader.repositoryRoot(for: root.path)
        XCTAssertEqual(repository.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path },
                       root.standardizedFileURL.resolvingSymlinksInPath().path)

        let snapshot = try XCTUnwrap(GitSnapshotReader.read(root: root.path, envFiles: [".env"]))
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertNil(snapshot.upstream)
        XCTAssertFalse(snapshot.isInitial)
        XCTAssertEqual(snapshot.files.map(\.path), ["notes.txt", "README.md"])

        let readme = try XCTUnwrap(snapshot.files.first { $0.path == "README.md" })
        XCTAssertEqual(readme.kind, .modified)
        XCTAssertEqual(readme.linesAdded, 2)
        XCTAssertEqual(readme.linesRemoved, 1)

        let notes = try XCTUnwrap(snapshot.files.first { $0.path == "notes.txt" })
        XCTAssertEqual(notes.kind, .untracked)
        XCTAssertEqual(notes.linesAdded, 3)

        XCTAssertEqual(snapshot.linesAdded, 5)
        XCTAssertEqual(snapshot.linesRemoved, 1)
        XCTAssertEqual(snapshot.ignoredEnvFiles, [".env"])

        XCTAssertEqual(snapshot.commits.count, 1)
        XCTAssertEqual(snapshot.commits.first?.subject, "initial")
        XCTAssertEqual(snapshot.commits.first?.isHead, true)
        XCTAssertEqual(snapshot.commits.first?.isLocalOnly, true, "nothing is pushed in a repository without a remote")
    }

    func testAFreshRepositoryWithoutCommitsIsInitial() throws {
        try write("a.txt", "x\n")
        let snapshot = try XCTUnwrap(GitSnapshotReader.read(root: root.path, envFiles: []))
        XCTAssertTrue(snapshot.isInitial)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.files.map(\.kind), [.untracked])
        XCTAssertEqual(snapshot.linesAdded, 1)
        XCTAssertTrue(snapshot.commits.isEmpty)
    }
}
