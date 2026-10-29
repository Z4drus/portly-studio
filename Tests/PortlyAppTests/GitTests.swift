import Foundation
import XCTest
@testable import PortlyApp

final class GitOutputParserTests: XCTestCase {
    private func nulJoined(_ fields: [String]) -> Data {
        Data((fields.joined(separator: "\0") + "\0").utf8)
    }

    func testStatusReadsBranchHeadersAndEntries() {
        let data = nulJoined([
            "# branch.oid 1234567",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 abc def Sources/App.swift",
            "1 A. N... 000000 100644 100644 000 abc Sources/New.swift",
            "1 .D N... 100644 100644 000000 abc abc README.md",
            "2 R. N... 100644 100644 100644 abc abc R100 Sources/Renamed.swift", "Sources/Old.swift",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? notes.txt",
        ])
        let status = GitOutputParser.parseStatus(data)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertFalse(status.isInitial)
        XCTAssertEqual(status.files.count, 6)

        let modified = status.files[0]
        XCTAssertEqual(modified.path, "Sources/App.swift")
        XCTAssertEqual(modified.kind, .modified)
        XCTAssertFalse(modified.staged)
        XCTAssertTrue(modified.unstaged)

        let added = status.files[1]
        XCTAssertEqual(added.kind, .added)
        XCTAssertTrue(added.staged)
        XCTAssertFalse(added.unstaged)

        XCTAssertEqual(status.files[2].kind, .deleted)

        let renamed = status.files[3]
        XCTAssertEqual(renamed.kind, .renamed)
        XCTAssertEqual(renamed.path, "Sources/Renamed.swift")
        XCTAssertEqual(renamed.previousPath, "Sources/Old.swift")

        XCTAssertEqual(status.files[4].kind, .conflicted)
        XCTAssertEqual(status.files[5].kind, .untracked)
        XCTAssertEqual(status.files[5].path, "notes.txt")
    }

    func testStatusHandlesDetachedHeadAndInitialRepository() {
        let data = nulJoined(["# branch.oid (initial)", "# branch.head (detached)"])
        let status = GitOutputParser.parseStatus(data)
        XCTAssertNil(status.branch)
        XCTAssertNil(status.upstream)
        XCTAssertTrue(status.isInitial)
        XCTAssertTrue(status.files.isEmpty)
    }

    func testNumstatReadsCountsBinariesAndRenames() {
        let data = Data("12\t3\tSources/App.swift\0-\t-\tlogo.png\05\t0\t\0old.swift\0new.swift\0".utf8)
        let counts = GitOutputParser.parseNumstat(data)
        XCTAssertEqual(counts.count, 3)
        XCTAssertEqual(counts[0].path, "Sources/App.swift")
        XCTAssertEqual(counts[0].added, 12)
        XCTAssertEqual(counts[0].removed, 3)
        XCTAssertFalse(counts[0].isBinary)
        XCTAssertEqual(counts[1].path, "logo.png")
        XCTAssertTrue(counts[1].isBinary)
        XCTAssertEqual(counts[2].path, "new.swift")
        XCTAssertEqual(counts[2].added, 5)
    }

    func testLogReadsCommitsRefsAndParents() {
        let record = ["aaaa", "bbbb cccc", "HEAD -> main, origin/main, tag: v1.0", "Noé", "1700000000", "feat: merge things"]
            .joined(separator: "\u{1f}") + "\u{1e}"
        let second = ["bbbb", "", "", "Someone", "1600000000", "initial"].joined(separator: "\u{1f}") + "\u{1e}"
        let commits = GitOutputParser.parseLog(Data((record + second).utf8))
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "aaaa")
        XCTAssertEqual(commits[0].shortHash, "aaaa")
        XCTAssertEqual(commits[0].parents, ["bbbb", "cccc"])
        XCTAssertEqual(commits[0].subject, "feat: merge things")
        XCTAssertTrue(commits[0].isHead)
        XCTAssertEqual(commits[0].branchNames, ["main", "origin/main", "v1.0"])
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(commits[1].parents, [])
        XCTAssertFalse(commits[1].isHead)
    }

    func testRemoteURLsBecomeBrowsablePages() {
        XCTAssertEqual(GitOutputParser.webURL(fromRemote: "git@github.com:Z4drus/portly-studio.git\n")?.absoluteString, "https://github.com/Z4drus/portly-studio")
        XCTAssertEqual(GitOutputParser.webURL(fromRemote: "https://github.com/Z4drus/portly-studio.git")?.absoluteString, "https://github.com/Z4drus/portly-studio")
        XCTAssertEqual(GitOutputParser.webURL(fromRemote: "ssh://git@gitlab.com/group/repo.git")?.absoluteString, "https://gitlab.com/group/repo")
        XCTAssertNil(GitOutputParser.webURL(fromRemote: ""))
        XCTAssertNil(GitOutputParser.webURL(fromRemote: "/Users/me/bare.git"))
        XCTAssertEqual(GitOutputParser.webURL(fromRemote: "https://user:secret@github.com/o/r.git")?.absoluteString, "https://github.com/o/r", "credentials never reach a link")
    }

    func testCountingLinesOfUntrackedFiles() {
        XCTAssertEqual(GitOutputParser.countLines(in: Data("a\nb\nc\n".utf8)).lines, 3)
        XCTAssertEqual(GitOutputParser.countLines(in: Data("a\nb".utf8)).lines, 2)
        XCTAssertEqual(GitOutputParser.countLines(in: Data()).lines, 0)
        let binary = GitOutputParser.countLines(in: Data([0x89, 0x50, 0x00, 0x47]))
        XCTAssertTrue(binary.isBinary)
        XCTAssertEqual(binary.lines, 0)
    }

    func testSnapshotTotalsAndSummary() {
        var snapshot = GitSnapshot()
        snapshot.files = [
            GitFileChange(path: "a", kind: .modified, staged: false, unstaged: true, linesAdded: 3, linesRemoved: 1),
            GitFileChange(path: "b", kind: .untracked, staged: false, unstaged: true, linesAdded: 10),
        ]
        snapshot.ahead = 2
        XCTAssertEqual(snapshot.linesAdded, 13)
        XCTAssertEqual(snapshot.linesRemoved, 1)
        XCTAssertFalse(snapshot.isClean)
        XCTAssertEqual(snapshot.summary, GitSnapshot.Summary(linesAdded: 13, linesRemoved: 1, ahead: 2, fileCount: 2, hasConflicts: false))
    }

    func testNoiseFoldersAreIgnoredByTheWatcher() {
        let root = "/Users/me/app"
        XCTAssertTrue(GitRepositoryMonitor.isNoise("/Users/me/app/node_modules/pkg", root: root))
        XCTAssertTrue(GitRepositoryMonitor.isNoise("/Users/me/app/.next/cache", root: root))
        XCTAssertTrue(GitRepositoryMonitor.isNoise("/Users/me/app/.git/objects/ab", root: root))
        XCTAssertTrue(GitRepositoryMonitor.isNoise("/Users/me/app/.git/logs/HEAD", root: root))
        XCTAssertTrue(GitRepositoryMonitor.isNoise("/Users/me/app/.git/hooks", root: root))
        XCTAssertFalse(GitRepositoryMonitor.isNoise("/Users/me/app/.git/refs/heads", root: root))
        XCTAssertFalse(GitRepositoryMonitor.isNoise("/Users/me/app/.git", root: root), "the folder itself moves on commit (HEAD, index)")
        XCTAssertFalse(GitRepositoryMonitor.isNoise("/Users/me/app/Sources", root: root))
    }

    func testTheAgentMessageEndsWithASpaceSoTypingCanContinue() {
        XCTAssertTrue(GitAgentMessages.commitAndPush.hasSuffix(" "))
        XCTAssertTrue(GitAgentMessages.commitAndPush.contains("commit and push"))
    }
}

final class GitGraphTests: XCTestCase {
    private func commit(_ hash: String, parents: [String], refs: [String] = []) -> GitCommit {
        GitCommit(hash: hash, parents: parents, subject: hash, author: "a", date: Date(), refs: refs)
    }

    func testLinearHistoryUsesOneLane() {
        let layout = GitGraph.layout([
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ])
        XCTAssertEqual(layout.laneCount, 1)
        XCTAssertEqual(layout.rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(layout.rows[0].edges, [GitGraph.Edge(fromLane: 0, toLane: 0, color: 0)])
        XCTAssertTrue(layout.rows[2].edges.isEmpty)
    }

    func testMergeForksASecondLaneThatRejoinsAtTheBase() {
        // m merges feature f into main over base a; f sits on its own lane.
        let layout = GitGraph.layout([
            commit("m", parents: ["b", "f"]),
            commit("f", parents: ["a"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ])
        XCTAssertEqual(layout.laneCount, 2)
        XCTAssertEqual(layout.rows[0].lane, 0)
        XCTAssertEqual(layout.rows[1].lane, 1, "the second parent forks into lane 1")
        XCTAssertEqual(layout.rows[2].lane, 0)
        XCTAssertEqual(layout.rows[3].lane, 0, "the base is reached in the first lane")
        // From the merge row, one edge stays in lane 0 (towards b) and one
        // bends into lane 1 (towards f).
        XCTAssertTrue(layout.rows[0].edges.contains { $0.fromLane == 0 && $0.toLane == 1 })
        XCTAssertTrue(layout.rows[0].edges.contains { $0.fromLane == 0 && $0.toLane == 0 })
        // While f is drawn, lane 0 passes behind it on its way to b.
        XCTAssertEqual(layout.rows[1].passingLanes, [0])
        // Both lanes converge on a: the edge leaving f's lane bends to lane 0
        // only when the next row is a, which is b here, so it runs straight.
        XCTAssertTrue(layout.rows[1].edges.contains { $0.fromLane == 1 && $0.toLane == 1 })
        XCTAssertTrue(layout.rows[2].edges.contains { $0.fromLane == 1 && $0.toLane == 0 }, "lane 1 bends into a's lane")
    }

    func testTwoBranchHeadsShareTheBase() {
        // Two tips, x and y, both on top of a: the second tip gets lane 1 and
        // its line bends back into lane 0 where a is drawn.
        let layout = GitGraph.layout([
            commit("x", parents: ["a"], refs: ["HEAD -> main"]),
            commit("y", parents: ["a"], refs: ["feature"]),
            commit("a", parents: []),
        ])
        XCTAssertEqual(layout.rows.map(\.lane), [0, 1, 0])
        XCTAssertEqual(layout.laneCount, 2)
        XCTAssertTrue(layout.rows[1].edges.contains { $0.fromLane == 1 && $0.toLane == 0 })
        XCTAssertTrue(layout.rows[1].edges.contains { $0.fromLane == 0 && $0.toLane == 0 })
    }

    func testEmptyHistoryIsEmpty() {
        let layout = GitGraph.layout([])
        XCTAssertTrue(layout.rows.isEmpty)
        XCTAssertEqual(layout.laneCount, 0)
    }
}
