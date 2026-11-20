import Foundation
import XCTest
@testable import PortlyApp

final class LaunchSessionsTests: XCTestCase {
    private func session(_ id: String, project: String, chat: String? = nil) -> TerminalSession {
        let pane = TerminalPaneConfig(id: "p_" + id, kind: chat == nil ? .shell : .agent, agentSessionID: chat)
        return TerminalSession(id: id, projectID: project, name: id, layout: .leaf(pane))
    }

    func testEveryListedProjectGetsOneFreshSessionAndTheRestIsPutAway() {
        let sessions = [
            session("a1", project: "a", chat: "c1"),
            session("a2", project: "a", chat: "c2"),
            session("b1", project: "b"),
            session("z1", project: "archived", chat: "c3"),
        ]
        let plan = LaunchSessions.plan(sessions: sessions, listedProjects: ["b", "a"], resumeNoteIDs: [])
        XCTAssertEqual(plan.kept, [])
        XCTAssertEqual(plan.freshSessionProjects, ["b", "a"], "one each, in sidebar order, however many sessions a project had")
    }

    func testAConversationWaitingForItsResumeNoteStaysAndCountsAsTheProjectsSession() {
        let sessions = [
            session("a1", project: "a", chat: "c1"),
            session("a2", project: "a", chat: "c2"),
            session("b1", project: "b", chat: "c3"),
        ]
        let plan = LaunchSessions.plan(sessions: sessions, listedProjects: ["a", "b"], resumeNoteIDs: ["c2", "unknown"])
        XCTAssertEqual(plan.kept.map(\.id), ["a2"])
        XCTAssertEqual(plan.freshSessionProjects, ["b"])
    }

    func testTheOldReopenSwitchIsNoLongerRead() throws {
        let json = Data(#"{"version":2,"sessions":[],"reopenSessionsAtLaunch":true}"#.utf8)
        let config = try JSONDecoder().decode(StudioConfig.self, from: json)
        XCTAssertFalse(config.restoreSessionsAtLaunch, "everybody had it on; the new default must win")
    }

    func testPendingResumeNotesAreListedWithoutBeingDelivered() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(["one": "carry on"]).write(to: url)
        XCTAssertEqual(ResumeNotes.pendingSessionIDs(url: url), ["one"])
        XCTAssertEqual(ResumeNotes.take(sessionID: "one", url: url), "carry on", "still there to be delivered")
        XCTAssertEqual(ResumeNotes.pendingSessionIDs(url: url), [])
    }
}

final class TranscriptSummaryTests: XCTestCase {
    private func lines(_ entries: [String]) -> Data {
        Data((entries.joined(separator: "\n") + "\n").utf8)
    }

    private let user = #"{"type":"user","isMeta":false,"message":{"role":"user","content":"Fix the login\nform please"},"timestamp":"2026-11-18T10:00:00.000Z"}"#
    private let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[]},"timestamp":"2026-11-18T10:05:00.000Z"}"#

    func testTheNewestTitlePromptAndExchangeWin() {
        let data = lines([
            #"{"type":"ai-title","aiTitle":"Old title","sessionId":"s"}"#,
            user,
            assistant,
            #"{"type":"ai-title","aiTitle":"Login form fix","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"Fix the login form please","sessionId":"s"}"#,
            #"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#,
        ])
        let summary = TranscriptSummary.reading(tail: data, isWholeFile: true)
        XCTAssertEqual(summary.title, "Login form fix")
        XCTAssertEqual(summary.lastPrompt, "Fix the login form please")
        XCTAssertEqual(summary.lastExchange, ClaudeTranscripts.parseTimestamp("2026-11-18T10:05:00.000Z"))
    }

    func testARenameBeatsClaudesOwnTitle() {
        let data = lines([
            #"{"type":"custom-title","customTitle":"Release 0.9","sessionId":"s"}"#,
            assistant,
            #"{"type":"ai-title","aiTitle":"Generated","sessionId":"s"}"#,
        ])
        XCTAssertEqual(TranscriptSummary.reading(tail: data, isWholeFile: true).title, "Release 0.9")
    }

    func testAnUntitledChatIsNamedByItsFirstRealPrompt() {
        var summary = TranscriptSummary.reading(tail: lines([assistant]), isWholeFile: true)
        XCTAssertNil(summary.title)
        summary.fill(fromHead: lines([
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: local command"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            user,
        ]))
        XCTAssertEqual(summary.title, "Fix the login form please")
    }

    func testAHeadCutMidLineDropsThePartialLine() {
        var summary = TranscriptSummary()
        summary.fill(fromHead: Data(#"{"type":"ai-title","aiTitle":"Cut"#.utf8))
        XCTAssertNil(summary.title)
    }

    func testAConversationNobodySpokeInIsLeftOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.jsonl")
        try lines([#"{"type":"permission-mode","permissionMode":"default"}"#]).write(to: empty)
        XCTAssertNil(ClaudeChats.read(url: empty, id: "empty"))

        let spoken = directory.appendingPathComponent("spoken.jsonl")
        try lines([user, assistant]).write(to: spoken)
        let chat = try XCTUnwrap(ClaudeChats.read(url: spoken, id: "spoken"))
        XCTAssertEqual(chat.title, "Fix the login form please")
        XCTAssertNil(chat.lastPrompt)
    }

    func testTitlesAreOneBoundedLine() {
        XCTAssertEqual(ClaudeChats.oneLine("  a\n\n b  "), "a b")
        XCTAssertNil(ClaudeChats.oneLine(" \n "))
        XCTAssertEqual(ClaudeChats.oneLine(String(repeating: "x", count: 500))?.count, ClaudeChats.maximumTitleLength)
    }

    func testBothFolderEncodingsAreLookedIn() {
        let names = ClaudeChats.directories(forProjectRoot: "/Users/me/my.app").map(\.lastPathComponent)
        XCTAssertEqual(names, ["-Users-me-my.app", "-Users-me-my-app"])
        XCTAssertEqual(ClaudeChats.directories(forProjectRoot: "/Users/me/app").count, 1)
    }
}

final class ChatHistoryTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        ClaudeTranscripts.parseTimestamp(text)!
    }

    private func chat(_ id: String, _ when: String, title: String = "Chat", prompt: String? = nil) -> ClaudeChat {
        ClaudeChat(id: id, title: title, lastPrompt: prompt, lastExchange: date(when))
    }

    func testChatsFallUnderTheirDayNewestFirst() {
        let now = date("2026-11-20T15:00:00Z")
        let chats = [
            chat("old", "2026-08-01T10:00:00Z"),
            chat("today-early", "2026-11-20T07:00:00Z"),
            chat("today-late", "2026-11-20T14:00:00Z"),
            chat("yesterday", "2026-11-19T22:30:00Z"),
            chat("week", "2026-11-16T10:00:00Z"),
            chat("month", "2026-11-01T10:00:00Z"),
        ]
        let groups = ChatHistory.grouped(chats, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.period), [.today, .yesterday, .previousWeek, .previousMonth, .older])
        XCTAssertEqual(groups.first?.chats.map(\.id), ["today-late", "today-early"])
    }

    func testSearchIgnoresAccentsAndCaseAndReadsThePromptToo() {
        let chats = [
            chat("a", "2026-11-20T10:00:00Z", title: "Mise à jour Next.js", prompt: "passe en 16.4"),
            chat("b", "2026-11-20T10:00:00Z", title: "Devis comptable"),
        ]
        XCTAssertEqual(ChatHistory.matching(chats, query: "MISE a jour").map(\.id), ["a"])
        XCTAssertEqual(ChatHistory.matching(chats, query: "next 16.4").map(\.id), ["a"], "every word, title or prompt")
        XCTAssertEqual(ChatHistory.matching(chats, query: "  ").count, 2)
        XCTAssertEqual(ChatHistory.matching(chats, query: "facture"), [])
    }
}
