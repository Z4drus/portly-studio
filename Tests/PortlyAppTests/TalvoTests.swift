import Foundation
import XCTest
@testable import PortlyApp

final class TalvoWorkspaceDataTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func bootstrap() throws -> TalvoBootstrap {
        let json = """
        {
          "seq": 40, "me": {"id":"u1","name":"Noé","email":"n@x.ch","role":"admin","initials":"NR","color":"#5e6ad2","active":true,"lastSeenAt":null},
          "settings": {"issuePrefix":"BLE"},
          "users": [{"id":"u1","name":"Noé","email":"n@x.ch","role":"admin","initials":"NR","color":"#5e6ad2","active":true,"lastSeenAt":null}],
          "statuses": [
            {"id":"st_todo","name":"À faire","type":"unstarted","color":"#ccc","position":1,"isDefault":true},
            {"id":"st_progress","name":"En cours","type":"started","color":"#fc4","position":2,"isDefault":false},
            {"id":"st_done","name":"Terminé","type":"completed","color":"#4c8","position":3,"isDefault":false},
            {"id":"st_cancel","name":"Annulé","type":"canceled","color":"#888","position":4,"isDefault":false}
          ],
          "labels": [{"id":"l1","name":"Bug","color":"#f00","description":null,"position":0,"archivedAt":null,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}],
          "projects": [
            {"id":"p1","slug":"portly","name":"Portly","summary":null,"icon":"rocket","color":"#0A84FF","status":"started","health":"onTrack","healthUpdatedAt":null,"priority":2,"leadId":"u1","startDate":null,"targetDate":"2026-12-31","visibility":"team","position":1,"archivedAt":null,"createdBy":"u1","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","startedAt":null,"completedAt":null,"canceledAt":null},
            {"id":"p2","slug":"old","name":"Old","summary":null,"icon":null,"color":"#888","status":"completed","health":null,"healthUpdatedAt":null,"priority":0,"leadId":null,"startDate":null,"targetDate":null,"visibility":"team","position":0,"archivedAt":null,"createdBy":null,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","startedAt":null,"completedAt":null,"canceledAt":null}
          ],
          "projectMembers": [{"projectId":"p1","userId":"u1","addedAt":"2026-01-01T00:00:00.000Z"}],
          "milestones": [{"id":"m1","projectId":"p1","name":"v1","description":null,"targetDate":null,"position":0,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}],
          "projectLinks": [],
          "issues": [
            {"id":"i1","number":12,"title":"Git button","statusId":"st_progress","priority":1,"projectId":"p1","milestoneId":"m1","assigneeId":"u1","creatorId":"u1","parentId":null,"estimate":null,"dueDate":null,"position":1,"labelIds":["l1"],"archivedAt":null,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-02T00:00:00.000Z","startedAt":null,"completedAt":null,"canceledAt":null},
            {"id":"i2","number":13,"title":"Done thing","statusId":"st_done","priority":0,"projectId":"p1","milestoneId":null,"assigneeId":null,"creatorId":null,"parentId":null,"estimate":2,"dueDate":"2026-01-01","position":2,"labelIds":[],"archivedAt":null,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","startedAt":null,"completedAt":"2026-01-03T00:00:00.000Z","canceledAt":null},
            {"id":"i3","number":14,"title":"Canceled","statusId":"st_cancel","priority":9,"projectId":"p1","milestoneId":null,"assigneeId":null,"creatorId":null,"parentId":null,"estimate":null,"dueDate":null,"position":3,"labelIds":[],"archivedAt":null,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","startedAt":null,"completedAt":null,"canceledAt":"2026-01-03T00:00:00.000Z"}
          ],
          "relations": [],
          "documents": [{"id":"d1","projectId":"p1","title":"Brief","icon":null,"color":null,"authorId":"u1","updatedById":null,"archivedAt":null,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-05T00:00:00.000Z"}],
          "favorites": [],
          "prefs": {}
        }
        """
        return try decoder.decode(TalvoBootstrap.self, from: Data(json.utf8))
    }

    func testBootstrapIsIndexedAndCounted() throws {
        var data = TalvoWorkspaceData()
        data.apply(try bootstrap())
        XCTAssertTrue(data.isLoaded)
        XCTAssertEqual(data.seq, 40)
        XCTAssertEqual(data.issuePrefix, "BLE")
        XCTAssertEqual(data.issues.count, 3)
        XCTAssertEqual(data.identifier(for: data.issues["i1"]!), "BLE-12")
        XCTAssertEqual(data.issues["i3"]?.priority, TalvoPriority.none, "an unknown priority decodes as none")
        XCTAssertEqual(data.openIssueCount(inProject: "p1"), 1)
        XCTAssertEqual(data.urgentOpenIssueCount(inProject: "p1"), 1)
        let progress = data.progress(ofProject: "p1")
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.completed, 1)
        XCTAssertEqual(progress.started, 1)
        XCTAssertEqual(progress.canceled, 1)
        XCTAssertEqual(progress.ratio, 0.5, accuracy: 0.001, "canceled issues do not count")
        XCTAssertEqual(data.orderedProjects.map(\.id), ["p1", "p2"], "finished projects go last")
        XCTAssertEqual(data.memberIDs(ofProject: "p1"), ["u1"])
        XCTAssertEqual(data.documents(inProject: "p1").map(\.id), ["d1"])
    }

    func testDeltaMergesDeletesAndReplacesMembers() throws {
        var data = TalvoWorkspaceData()
        data.apply(try bootstrap())
        let json = """
        {
          "seq": 45, "reset": false, "users": [], "labels": [], "statuses": [],
          "projects": [],
          "projectMembers": [{"projectId":"p1","userId":"u2","addedAt":"2026-02-01T00:00:00.000Z"}],
          "milestones": [], "projectLinks": [],
          "issues": [{"id":"i1","number":12,"title":"Git button, renamed","statusId":"st_done","priority":1,"projectId":"p1","milestoneId":"m1","assigneeId":"u1","creatorId":"u1","parentId":null,"estimate":null,"dueDate":null,"position":1,"labelIds":[],"archivedAt":null,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-02-02T00:00:00.000Z","startedAt":null,"completedAt":"2026-02-02T00:00:00.000Z","canceledAt":null}],
          "relations": [], "documents": [], "favorites": [],
          "touched": {"issues": ["i1"], "projects": ["p1"], "documents": []},
          "deleted": {"issue": ["i2"], "document": ["d1"]}
        }
        """
        let delta = try decoder.decode(TalvoSyncDelta.self, from: Data(json.utf8))
        data.apply(delta)
        XCTAssertEqual(data.seq, 45)
        XCTAssertEqual(data.issues["i1"]?.title, "Git button, renamed")
        XCTAssertNil(data.issues["i2"])
        XCTAssertNil(data.documents["d1"])
        XCTAssertEqual(data.memberIDs(ofProject: "p1"), ["u2"], "members of a touched project are replaced")
        XCTAssertEqual(data.openIssueCount(inProject: "p1"), 0)
    }

    func testIssueIdentifiersResolveToIDs() throws {
        var data = TalvoWorkspaceData()
        data.apply(try bootstrap())
        XCTAssertEqual(TalvoWorkspaceData.issueID(forIdentifier: "BLE-12", in: data), "i1")
        XCTAssertEqual(TalvoWorkspaceData.issueID(forIdentifier: "ble-13", in: data), "i2")
        XCTAssertEqual(TalvoWorkspaceData.issueID(forIdentifier: "14", in: data), "i3")
        XCTAssertNil(TalvoWorkspaceData.issueID(forIdentifier: "XYZ-12", in: data), "another prefix is another space")
        XCTAssertNil(TalvoWorkspaceData.issueID(forIdentifier: "BLE-999", in: data))
        XCTAssertNil(TalvoWorkspaceData.issueID(forIdentifier: "nope", in: data))
    }

    func testAnOlderDeltaNeverMovesTheSequenceBack() throws {
        var data = TalvoWorkspaceData()
        data.apply(try bootstrap())
        let json = """
        {"seq": 10, "reset": false, "users": [], "labels": [], "statuses": [], "projects": [], "projectMembers": [], "milestones": [], "projectLinks": [], "issues": [], "relations": [], "documents": [], "favorites": [], "touched": {"issues": [], "projects": [], "documents": []}, "deleted": {}}
        """
        data.apply(try decoder.decode(TalvoSyncDelta.self, from: Data(json.utf8)))
        XCTAssertEqual(data.seq, 40)
    }

    func testWorkspaceDataRoundTripsThroughJSON() throws {
        var data = TalvoWorkspaceData()
        data.apply(try bootstrap())
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(TalvoWorkspaceData.self, from: encoded)
        XCTAssertEqual(decoded, data)
    }
}

final class TalvoClientTests: XCTestCase {
    func testServerAddressesAreNormalised() {
        XCTAssertEqual(TalvoClient.normalizedBaseURL("talvo.bleeze.ch")?.absoluteString, "https://talvo.bleeze.ch")
        XCTAssertEqual(TalvoClient.normalizedBaseURL(" https://talvo.bleeze.ch/projets/x?y=1 ")?.absoluteString, "https://talvo.bleeze.ch")
        XCTAssertEqual(TalvoClient.normalizedBaseURL("http://localhost:4100")?.absoluteString, "http://localhost:4100")
        XCTAssertNil(TalvoClient.normalizedBaseURL("http://talvo.bleeze.ch"), "plain http is only for the loopback")
        XCTAssertNil(TalvoClient.normalizedBaseURL("http://mac.local:4100"), "a token must not cross the network in clear")
        XCTAssertNil(TalvoClient.normalizedBaseURL(""))
        XCTAssertNil(TalvoClient.normalizedBaseURL("not a url"))
    }

    func testStreamLinesBecomeEvents() {
        var name = "message"
        XCTAssertNil(TalvoClient.parseStreamLine("event: seq", eventName: &name))
        XCTAssertEqual(name, "seq")
        XCTAssertEqual(TalvoClient.parseStreamLine("data: 1234", eventName: &name), .seq(1234))
        XCTAssertEqual(name, "message", "the name is consumed with its data")
        XCTAssertNil(TalvoClient.parseStreamLine("", eventName: &name))
        XCTAssertNil(TalvoClient.parseStreamLine("event:ping", eventName: &name))
        XCTAssertEqual(TalvoClient.parseStreamLine("data:", eventName: &name), .ping)
        XCTAssertNil(TalvoClient.parseStreamLine(": comment", eventName: &name))
        XCTAssertNil(TalvoClient.parseStreamLine("data: hello", eventName: &name), "a message without a known name is ignored")
        XCTAssertNil(TalvoClient.parseStreamLine("event: revoked", eventName: &name))
        XCTAssertEqual(TalvoClient.parseStreamLine("data: ", eventName: &name), .revoked)
        XCTAssertNil(TalvoClient.parseStreamLine("event: replaced", eventName: &name))
        XCTAssertEqual(TalvoClient.parseStreamLine("data:", eventName: &name), .replaced)
    }

    func testDatesParseInBothShapes() {
        XCTAssertNotNil(TalvoDates.parse("2026-10-25T09:12:03.123Z"))
        XCTAssertNotNil(TalvoDates.parse("2026-10-25T09:12:03Z"))
        XCTAssertNotNil(TalvoDates.parse("2026-11-30"))
        XCTAssertNil(TalvoDates.parse(nil))
        XCTAssertNil(TalvoDates.parse(""))
        XCTAssertTrue(TalvoDates.isPast("2000-01-01"))
        XCTAssertFalse(TalvoDates.isPast("2999-01-01"))
    }

    func testSearchFoldKeepsHyphensAndDropsAccents() {
        XCTAssertEqual(TalvoSearch.fold("  BLE-12 "), "ble-12")
        XCTAssertEqual(TalvoSearch.fold("Référence Épurée"), "reference epuree")
        XCTAssertTrue(TalvoSearch.fold("BLE-12").contains(TalvoSearch.fold("ble-1")))
    }

    func testLooseJSONDecodesAnyShape() throws {
        let json = #"{"from":"À faire","to":"En cours","count":3,"flag":true,"none":null,"list":[1,"a"]}"#
        let value = try JSONDecoder().decode(TalvoJSON.self, from: Data(json.utf8))
        XCTAssertEqual(value["from"]?.displayText, "À faire")
        XCTAssertEqual(value["count"]?.displayText, "3")
        XCTAssertEqual(value["flag"]?.displayText, "yes")
        XCTAssertNil(value["none"]?.displayText)
        XCTAssertEqual(value["list"]?.displayText, "1, a")
        XCTAssertNil(value["missing"])
    }
}
