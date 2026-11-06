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

    @Test func unknownRepoStaysPut() {
        #expect(TabGrouping.anchor(repos: ["a", nil, "a"], moving: 1) == nil)
    }

    @Test func parsesMeta() {
        let repo = TabRepo(meta: "BA3F1D\tclaylib\tclaylib\n", branch: "main\n".trimmingCharacters(in: .newlines))
        #expect(repo.name == "claylib")
        #expect(repo.color != nil)
        #expect(repo.branch == "main")
        let none = TabRepo(meta: "default\t\t", branch: "")
        #expect(none.name == "")
        #expect(none.color == nil)
        #expect(none.branch == nil)
    }
}

struct TabStripTests {
    @Test func groupsAreRunsOfOneRepo() {
        #expect(runs(["a", "a", "", "b", "b"], by: { $0 }) == [["a", "a"], [""], ["b", "b"]])
        #expect(runs([String](), by: { $0 }).isEmpty)
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
