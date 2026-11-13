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

    @Test func oldestFirstAndBrokenFilesSkipped() {
        let tasks = HumanTask.parse([
            file(#"{"id": "new", "title": "", "created": 9}"#),
            file("{half a file"),
            file(#"{"id": "old", "title": "", "created": 1}"#),
        ])
        #expect(tasks.map(\.id) == ["old", "new"])
    }
}
