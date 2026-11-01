import Foundation
import SQLite3
import XCTest
@testable import PortlyApp

final class ThingsModelTests: XCTestCase {
    func testPackedDatesRoundTrip() {
        let packed = ThingsDate.packed(year: 2026, month: 11, day: 3)
        XCTAssertEqual(ThingsDate.components(packed: packed), DateComponents(year: 2026, month: 11, day: 3))
        XCTAssertNil(ThingsDate.components(packed: 0))
        XCTAssertNil(ThingsDate.components(packed: 2026 << 16))
    }

    func testAgentReportsMoveTheBranch() {
        XCTAssertEqual(ThingsBranch.next(.review, status: .busy), .working)
        XCTAssertEqual(ThingsBranch.next(.working, status: .waiting), .waiting)
        XCTAssertEqual(ThingsBranch.next(.working, status: .idle), .review)
        XCTAssertEqual(ThingsBranch.next(.waiting, status: .gone), .review)
        XCTAssertEqual(ThingsBranch.next(.review, status: .idle), .review)
        XCTAssertEqual(ThingsBranch.next(.review, status: .gone), .review)
    }

    func testOnlyYouCloseABranch() {
        XCTAssertEqual(ThingsBranch.next(.done, status: .busy), .done)
        XCTAssertEqual(ThingsBranch.next(.done, status: .waiting), .done)
    }

    func testToDosWithWorkComeFirstNewestOnTop() {
        let tasks = (0..<4).map { task("t\($0)", order: $0) }
        let old = branch("b1", task: "t2", at: 100)
        let new = branch("b2", task: "t3", at: 200)
        let rows = ThingsBoard.rows(tasks: tasks, branches: [old, new])
        XCTAssertEqual(rows.map(\.id), ["t3", "t2", "t0", "t1"])
        XCTAssertEqual(rows[0].branches, [new])
    }

    func testBranchesOfAToDoKeepTheirOrderAndCounts() {
        let rows = ThingsBoard.rows(
            tasks: [task("t0", order: 0)],
            branches: [
                branch("late", task: "t0", at: 300, state: .review),
                branch("early", task: "t0", at: 100, state: .working),
                branch("asks", task: "t0", at: 200, state: .waiting),
            ]
        )
        XCTAssertEqual(rows[0].branches.map(\.id), ["early", "asks", "late"])
        XCTAssertEqual(rows[0].workingCount, 1)
        XCTAssertEqual(rows[0].needsYouCount, 2)
    }

    func testExcerptDropsMarkupAndCuts() {
        XCTAssertEqual(ThingsBoard.excerpt(of: "  <pasted_content id=\"1\">\nFais   les\narticles</pasted_content> "), "Fais les articles")
        let long = String(repeating: "mot ", count: 50)
        let cut = ThingsBoard.excerpt(of: long, limit: 20)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, 21)
    }

    func testPanelStateDecodesOlderFilesAndSettles() throws {
        var state = try JSONDecoder.thingsPanel.decode(ThingsPanelState.self, from: Data("{}".utf8))
        XCTAssertTrue(state.autoSort)
        XCTAssertTrue(state.branches.isEmpty)

        state.branches = [
            branch("a", task: "t", at: 1, state: .working),
            branch("b", task: "t", at: 2, state: .waiting),
            branch("c", task: "t", at: 3, state: .done),
        ]
        let data = try JSONEncoder.thingsPanel.encode(state)
        var loaded = try JSONDecoder.thingsPanel.decode(ThingsPanelState.self, from: data)
        loaded.settleAfterLaunch()
        XCTAssertEqual(loaded.branches.map(\.state), [.review, .review, .done])
    }

    private func task(_ id: String, order: Int) -> ThingsTask {
        ThingsTask(id: id, title: id, notes: "", projectTitle: nil, deadline: nil, order: order)
    }

    private func branch(_ id: String, task: String, at seconds: TimeInterval, state: ThingsBranch.State = .working) -> ThingsBranch {
        let date = Date(timeIntervalSince1970: seconds)
        return ThingsBranch(id: id, taskID: task, label: id, paneID: "pane_\(id)", state: state, createdAt: date, updatedAt: date)
    }
}

final class ClaudeActivityTests: XCTestCase {
    func testSessionFileStatuses() {
        func status(_ extra: [String: Any]) -> AgentStatus? {
            var json: [String: Any] = ["pid": 42, "sessionId": "s", "cwd": "/tmp"]
            json.merge(extra) { $1 }
            return ClaudeActivity.session(json: json)?.status
        }
        XCTAssertEqual(status(["status": "busy"]), .busy)
        XCTAssertEqual(status(["status": "waiting"]), .waiting)
        XCTAssertEqual(status(["status": "idle"]), .idle)
        XCTAssertEqual(status(["tempo": "blocked", "status": "busy"]), .waiting)
        XCTAssertNil(ClaudeActivity.session(json: ["pid": 42, "cwd": "/tmp"]))
    }

    func testAProcessBelongsToTheNearestTerminalShell() {
        let parents: [Int32: Int32] = [900: 800, 800: 700, 700: 1, 50: 40, 40: 1]
        let shells: [Int32: String] = [700: "pane_a"]
        let lookup: (Int32) -> Int32? = { parents[$0] }
        XCTAssertEqual(ClaudeActivity.terminal(of: 900, shells: shells, parent: lookup), "pane_a")
        XCTAssertEqual(ClaudeActivity.terminal(of: 700, shells: shells, parent: lookup), "pane_a")
        XCTAssertNil(ClaudeActivity.terminal(of: 50, shells: shells, parent: lookup))
    }

    func testTheLatestHumanPromptSkipsEverythingElse() throws {
        let lines: [[String: Any]] = [
            ["type": "user", "promptId": "p1", "origin": ["kind": "human"], "message": ["content": "Écris deux articles"]],
            ["type": "assistant", "message": ["content": []]],
            ["type": "user", "promptId": "p1", "toolUseResult": [:], "message": ["content": [["type": "tool_result", "content": "ok"]]]],
            ["type": "user", "isMeta": true, "uuid": "m", "message": ["content": "Caveat: …"]],
            ["type": "user", "uuid": "c", "message": ["content": "<command-name>/clear</command-name>"]],
            ["type": "last-prompt", "lastPrompt": "x"],
        ]
        let data = try lines.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(Data()) { $0 + $1 + Data("\n".utf8) }
        XCTAssertEqual(
            ClaudeActivity.latestHumanPrompt(inTail: data, isWholeFile: true),
            ClaudeActivity.HumanPrompt(id: "p1", text: "Écris deux articles")
        )
    }

    func testTextBlocksCountAndAPartialFirstLineIsIgnored() throws {
        let entry: [String: Any] = [
            "type": "user", "uuid": "u2",
            "message": ["content": [["type": "text", "text": "Fais le devis"], ["type": "image"]]],
        ]
        let partial = Data(#"ent":"user","promptId":"broken"}"#.utf8) + Data("\n".utf8)
        let data = partial + (try JSONSerialization.data(withJSONObject: entry))
        XCTAssertEqual(ClaudeActivity.latestHumanPrompt(inTail: data, isWholeFile: false)?.text, "Fais le devis")
    }

    func testTranscriptFoldersReplaceEveryOddCharacter() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projects) }
        let folder = projects.appendingPathComponent("-Users-me--config-my-app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("abc.jsonl")
        try Data().write(to: file)
        XCTAssertEqual(ClaudeActivity.transcriptURL(sessionID: "abc", cwd: "/Users/me/.config/my_app", projects: projects), file)
        XCTAssertNil(ClaudeActivity.transcriptURL(sessionID: "nope", cwd: "/Users/me", projects: projects))
    }
}

final class ThingsTriageTests: XCTestCase {
    private let tasks = [
        ThingsTask(id: "UUID-SEO", title: "Accompagnement SEO Swissmedsolutions", notes: "Articles\net indexation", projectTitle: nil, deadline: nil, order: 0),
        ThingsTask(id: "UUID-DEVIS", title: "Devis Oneway", notes: "", projectTitle: "Ventes", deadline: nil, order: 1),
    ]

    func testTheMessageListsShortIdsAndCutsLongPrompts() {
        let request = ThingsTriage.Request(prompt: String(repeating: "a", count: 5000), directory: "/Users/me/site", projectName: "Site")
        let (text, ids) = ThingsTriage.message(tasks: tasks, request: request)
        XCTAssertEqual(ids, ["t1": "UUID-SEO", "t2": "UUID-DEVIS"])
        XCTAssertTrue(text.contains("- t1: Accompagnement SEO Swissmedsolutions — notes : Articles et indexation"))
        XCTAssertTrue(text.contains("- t2: Devis Oneway (projet Things : Ventes)"))
        XCTAssertTrue(text.contains("Projet Portly : Site"))
        XCTAssertTrue(text.contains("[…]"))
        XCTAssertFalse(text.contains(String(repeating: "a", count: 4001)))
    }

    func testVerdicts() throws {
        let ids = ["t1": "UUID-SEO"]
        func verdict(_ json: String) throws -> ThingsTriage.Verdict {
            try ThingsTriage.verdict(output: Data(json.utf8), ids: ids)
        }
        XCTAssertEqual(
            try verdict(#"{"is_error":false,"structured_output":{"taskId":"t1","label":"« Rédiger 2 articles. »"}}"#),
            .task(id: "UUID-SEO", label: "Rédiger 2 articles")
        )
        XCTAssertEqual(try verdict(#"{"is_error":false,"structured_output":{"taskId":null,"label":null}}"#), .unrelated)
        XCTAssertEqual(try verdict(#"{"is_error":false,"structured_output":{"taskId":"t9","label":"x"}}"#), .unrelated)
        XCTAssertEqual(
            try verdict(#"{"is_error":false,"structured_output":{"taskId":"t1","label":""}}"#),
            .task(id: "UUID-SEO", label: "Avancer la tâche")
        )
        XCTAssertThrowsError(try verdict(#"{"is_error":true,"result":"rate limited"}"#))
        XCTAssertThrowsError(try verdict("not json"))
    }

    func testTheRunHasNoToolsNoMCPAndNoSettings() {
        let arguments = ThingsTriage.arguments()
        XCTAssertEqual(arguments.first, "-p")
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        XCTAssertEqual(value(after: "--model"), "sonnet")
        XCTAssertEqual(value(after: "--effort"), "medium")
        XCTAssertEqual(value(after: "--tools"), "")
        XCTAssertEqual(value(after: "--setting-sources"), "")
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
    }
}

final class ThingsDatabaseTests: XCTestCase {
    func testLinksEscapeEverything() {
        let url = ThingsLinks.add(title: "Devis 2/3 & SEO", areaID: "A1")
        XCTAssertEqual(url?.absoluteString, "things:///add?list-id=A1&title=Devis%202%2F3%20%26%20SEO")
        XCTAssertEqual(
            ThingsLinks.complete(taskID: "T1", token: "tok")?.absoluteString,
            "things:///update?auth-token=tok&completed=true&id=T1"
        )
    }

    func testTheProjetsAreaIsPreferred() {
        let areas = [ThingsArea(id: "a", title: "Perso"), ThingsArea(id: "b", title: "Projets")]
        XCTAssertEqual(ThingsDatabase.preferredArea(in: areas, picked: nil)?.id, "b")
        XCTAssertEqual(ThingsDatabase.preferredArea(in: areas, picked: "a")?.id, "a")
        XCTAssertEqual(ThingsDatabase.preferredArea(in: areas, picked: "gone")?.id, "b")
        XCTAssertNil(ThingsDatabase.preferredArea(in: [], picked: nil))
    }

    func testReadsOpenToDosOfTheAreaAndItsProjects() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = try ThingsDatabase.read(at: url, pickedAreaID: nil)
        XCTAssertEqual(snapshot.area?.title, "Projets")
        XCTAssertEqual(snapshot.tasks.map(\.title), ["Loose", "In project"])
        XCTAssertEqual(snapshot.tasks.last?.projectTitle, "Site")
        XCTAssertEqual(snapshot.tasks.first?.deadline, DateComponents(year: 2026, month: 11, day: 3))
        XCTAssertEqual(snapshot.urlToken, "secret")
        XCTAssertEqual(try ThingsDatabase.closedTasks(among: ["loose", "done", "missing"], at: url), ["done", "missing"])
    }

    /// A Things-shaped database with only the columns Portly reads.
    private func makeDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("main.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let deadline = ThingsDate.packed(year: 2026, month: 11, day: 3)
        let sql = """
        CREATE TABLE TMArea (uuid TEXT, title TEXT, "index" INTEGER);
        CREATE TABLE TMSettings (uuid TEXT, uriSchemeAuthenticationToken TEXT);
        CREATE TABLE TMTask (uuid TEXT, type INTEGER, status INTEGER, trashed INTEGER, title TEXT, notes TEXT,
          area TEXT, project TEXT, heading TEXT, deadline INTEGER, "index" INTEGER, rt1_recurrenceRule BLOB);
        INSERT INTO TMArea VALUES ('perso', 'Perso', 0), ('projets', 'Projets', 1);
        INSERT INTO TMSettings VALUES ('s', 'secret');
        INSERT INTO TMTask VALUES ('loose', 0, 0, 0, 'Loose', '', 'projets', NULL, NULL, \(deadline), 0, NULL);
        INSERT INTO TMTask VALUES ('site', 1, 0, 0, 'Site', '', 'projets', NULL, NULL, NULL, 1, NULL);
        INSERT INTO TMTask VALUES ('head', 2, 0, 0, 'Heading', '', NULL, 'site', NULL, NULL, 0, NULL);
        INSERT INTO TMTask VALUES ('inproject', 0, 0, 0, 'In project', '', NULL, NULL, 'head', NULL, 0, NULL);
        INSERT INTO TMTask VALUES ('done', 0, 3, 0, 'Done', '', 'projets', NULL, NULL, NULL, 2, NULL);
        INSERT INTO TMTask VALUES ('trashed', 0, 0, 1, 'Trashed', '', 'projets', NULL, NULL, NULL, 3, NULL);
        INSERT INTO TMTask VALUES ('template', 0, 0, 0, 'Every week', '', 'projets', NULL, NULL, NULL, 4, x'00');
        INSERT INTO TMTask VALUES ('other', 0, 0, 0, 'Other area', '', 'perso', NULL, NULL, NULL, 0, NULL);
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
        return url
    }
}
