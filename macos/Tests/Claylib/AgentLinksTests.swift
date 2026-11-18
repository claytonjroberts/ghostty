import Foundation
import Testing
@testable import Ghostty

struct AgentLinksTests {
    @Test func linksNameOnlyAnAgent() {
        #expect(AgentLinks.agent("claylib-task://attach/worker-mothership") == "worker-mothership")
        #expect(AgentLinks.agent("claylib-task://run/ab12") == nil)
        #expect(AgentLinks.agent("claylib-task://attach/a;b") == nil)
        #expect(AgentLinks.agent("claylib-task://attach/a%20b") == nil)
        #expect(AgentLinks.agent("claylib-task://attach/a/b") == nil)
        #expect(AgentLinks.agent("https://attach/a") == nil)
    }

    /// The path mirrors the summoner repo's; it went stale once when it was renamed from agent-dispatcher.
    @Test func pathPointsAtTheSummonerInstall() {
        #expect(AgentLinks.project == FileManager.default.homeDirectoryForCurrentUser.path + "/repos/summoner-deploy")
    }
}
