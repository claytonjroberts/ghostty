import Foundation
import Testing
@testable import Ghostty

struct HumanTasksTests {
    private func file(_ json: String) -> Data { Data(json.utf8) }

    @Test func fileFromBeforeKindsIsAnOpenAction() throws {
        let task = try #require(HumanTask.parse([file(#"{"id": "a", "title": "Log in", "created": 1, "done_at": null}"#)]).first)
        #expect(task.kind == .action)
        #expect(task.command.isEmpty && task.options.isEmpty && task.answer.isEmpty)
        #expect(!task.done)
    }

    @Test func questionWithOptionsAndAnswer() throws {
        let json = #"""
        {"id": "q", "title": "Squash?", "created": 2, "kind": "question", "command": "", "host": "",
         "options": ["squash", "merge"], "answer": "squash", "done_at": 3.5}
        """#
        let task = try #require(HumanTask.parse([file(json)]).first)
        #expect(task.kind == .question)
        #expect(task.options == ["squash", "merge"])
        #expect(task.answer == "squash")
        #expect(task.done)
    }

    @Test func failedRunKeepsItsResult() throws {
        let json = #"{"id": "f", "title": "", "created": 1, "exit_status": 255, "output": "a\nb\nc"}"#
        let task = try #require(HumanTask.parse([file(json)]).first)
        #expect(task.exitStatus == 255)
        #expect(task.outputTail(lines: 2) == "b\nc")
        #expect(task.note.isEmpty)
        let noted = try #require(HumanTask.parse([file(#"{"id": "n", "title": "", "created": 1, "note": "needs a relink"}"#)]).first)
        #expect(noted.note == "needs a relink")
        let rejected = try #require(HumanTask.parse([file(#"{"id": "r", "title": "", "created": 1, "rejection": "not now", "done_at": 2}"#)]).first)
        #expect(rejected.rejection == "not now" && rejected.done)
        #expect(!task.done)
    }

    @Test func blockersComeFirstWithWhoAskedAndWhy() {
        let tasks = HumanTask.parse([
            file(#"{"id": "later", "title": "", "created": 1}"#),
            file(#"{"id": "now", "title": "", "created": 2, "blocking": true, "requester": "coordinator", "details": "why"}"#),
        ])
        #expect(tasks.map(\.id) == ["now", "later"])
        #expect(tasks[0].requester == "coordinator" && tasks[0].details == "why")
        #expect(tasks[1].requester.isEmpty && !tasks[1].blocking)
    }

    @Test func taskSessionsAreTheOnesHumanTaskStarts() {
        #expect(HumanTasks.isTaskSession("task-0fc81255"))
        #expect(!HumanTasks.isTaskSession("agent-worker-1"))
        #expect(!HumanTasks.isTaskSession("76"))
    }

    @Test func oldestFirstAndBrokenFilesSkipped() {
        let tasks = HumanTask.parse([
            file(#"{"id": "new", "title": "", "created": 9}"#),
            file("{half a file"),
            file(#"{"id": "old", "title": "", "created": 1}"#),
        ])
        #expect(tasks.map(\.id) == ["old", "new"])
    }

    @Test func fyiDecodesAndAnUnknownKindSkipsOnlyItsTask() {
        let tasks = HumanTask.parse([
            file(#"{"id": "fyi", "title": "", "created": 1, "kind": "info"}"#),
            file(#"{"id": "future", "title": "", "created": 2, "kind": "someday"}"#),
            file(#"{"id": "act", "title": "", "created": 3}"#),
        ])
        #expect(tasks.map(\.id) == ["fyi", "act"])
        #expect(tasks.first?.kind == .info)
    }

    @Test func permissionShowsItsCallAsThePageDoes() throws {
        func call(_ details: String) throws -> HumanTask.Call {
            let json = try JSONSerialization.data(withJSONObject: ["id": "p", "title": "", "created": 1, "kind": "permission", "tool": "Edit", "details": details])
            let task = try #require(HumanTask.parse([json]).first)
            #expect(task.kind == .permission && task.tool == "Edit")
            return task.call
        }
        #expect(try call(#"{"command": "ls", "description": "List"}"#) == .command("ls", description: "List"))
        #expect(try call(#"{"file_path": "/a", "old_string": "x\ny", "new_string": "z"}"#) == .diff(path: "/a", removed: ["x", "y"], added: ["z"]))
        #expect(try call(#"{"file_path": "/a", "content": "new"}"#) == .diff(path: "/a", removed: [], added: ["new"]))
        #expect(try call(#"{"path": "/d"}"#) == .path("/d"))
        #expect(try call(#"{"url": "u"}"#) == .raw("{\n  \"url\" : \"u\"\n}"))
        #expect(try call(#"{"command": "cut off"#) == .raw(#"{"command": "cut off"#))
    }

    @Test func linksNameOnlyATaskOrAnAgent() {
        #expect(HumanTaskLinks.link("claylib-task://run/ab12") == .run("ab12"))
        #expect(HumanTaskLinks.link("claylib-task://attach/worker-mothership") == .attach("worker-mothership"))
        #expect(HumanTaskLinks.link("claylib-task://run/ab12/rm%20-rf") == nil)
        #expect(HumanTaskLinks.link("claylib-task://attach/a;b") == nil)
        #expect(HumanTaskLinks.link("claylib-task://attach/a%20b") == nil)
        #expect(HumanTaskLinks.link("claylib-task://exec/ab12") == nil)
        #expect(HumanTaskLinks.link("https://run/ab12") == nil)
    }
}
