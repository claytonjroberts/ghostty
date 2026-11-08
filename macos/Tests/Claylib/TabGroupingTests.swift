import AppKit
import Testing
@testable import Ghostty

struct TabGroupingTests {
    @Test func togetherAlreadyStaysPut() {
        #expect(TabGrouping.anchor(repos: ["a", "a", "b"], moving: 1) == nil)
        #expect(TabGrouping.anchor(repos: ["a", "b", "c"], moving: 2) == nil)
    }

    @Test func strayTabGoesAfterItsRepo() {
        #expect(TabGrouping.anchor(repos: ["a", "b", "a"], moving: 2) == 0)
        #expect(TabGrouping.anchor(repos: ["a", "a", "b", "a"], moving: 3) == 1)
        // A tab whose directory changed mid-group goes after its new repo's last tab.
        #expect(TabGrouping.anchor(repos: ["b", "a", "b", "b"], moving: 0) == 3)
    }

    @Test func dropsLandOnTheSideTheyCameFrom() {
        let order = [1, 2, 3, 4, 5]
        // From the right: before the target. From the left: after it.
        #expect(TabGrouping.drop(order: order, moving: [4], onto: [2])! == (2, true))
        #expect(TabGrouping.drop(order: order, moving: [1], onto: [3])! == (3, false))
        // A group lands before or after the whole target group.
        #expect(TabGrouping.drop(order: order, moving: [4, 5], onto: [1, 2])! == (1, true))
        #expect(TabGrouping.drop(order: order, moving: [1, 2], onto: [3, 4])! == (4, false))
        // Onto itself: nowhere to go.
        #expect(TabGrouping.drop(order: order, moving: [3], onto: [3]) == nil)
        // A tab dropped on its own group's label goes to the group's front.
        #expect(TabGrouping.drop(order: order, moving: [3], onto: [2, 3])! == (2, true))
    }

    @Test func unknownRepoStaysPut() {
        #expect(TabGrouping.anchor(repos: ["a", nil, "a"], moving: 1) == nil)
    }

    @Test func parsesMeta() {
        let repo = TabRepo(meta: "BA3F1D\tclaylib\tclaylib\n", branch: "main\n".trimmingCharacters(in: .newlines), dir: "/r")
        #expect(repo.name == "claylib")
        #expect(repo.color != nil)
        #expect(repo.branch == "main")
        let none = TabRepo(meta: "default\t\t", branch: "", dir: "/r")
        #expect(none.name == "")
        #expect(none.color == nil)
        #expect(none.branch == nil)
    }

    @Test func homeIsItsOwnGroup() {
        #expect(TabRepo(meta: "default\t\t", branch: nil, dir: NSHomeDirectory()).name == TabRepo.home)
        #expect(TabRepo(meta: "default\t\t", branch: nil, dir: NSHomeDirectory() + "/Downloads").name == "")
    }
}

struct TabStripTests {
    @Test func groupsAreRunsOfOneRepo() {
        #expect(runs(["a", "a", "", "b", "b"], by: { $0 }) == [["a", "a"], [""], ["b", "b"]])
        #expect(runs([String](), by: { $0 }).isEmpty)
    }

    @Test func rowsKeepGroupsWhole() {
        // A group that doesn't fit moves to the next row; one wider than a row still splits.
        #expect(wrapRows([[1, 2], [3, 4, 5]], perRow: 4) == [[1, 2], [3, 4, 5]])
        #expect(wrapRows([[1], [2, 3]], perRow: 3) == [[1, 2, 3]])
        #expect(wrapRows([[1], [2, 3, 4, 5]], perRow: 3) == [[1], [2, 3, 4], [5]])
        #expect(wrapRows([[Int]](), perRow: 3).isEmpty)
    }

    @Test func darkTextOnLightColors() {
        #expect(readable(on: .white) != readable(on: .black))
        #expect(readable(on: .white) == readable(on: .systemYellow))
    }

    /// Tab changes arrive inside AppKit's layout (a restored tab made key); publishing there
    /// re-lays out the strip mid-pass, which AppKit throws on. A burst is one later redraw.
    @Test @MainActor func changesPublishOnceOnTheNextTurn() async {
        let tabs = ClaylibTabs.shared
        let before = tabs.revision
        tabs.changed()
        tabs.changed()
        #expect(tabs.revision == before)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(tabs.revision == before &+ 1)
    }
}
