import AppKit
import Testing
@testable import Ghostty

struct ClaudeSessionTests {
    private func session(_ fields: String) -> ClaudeSession? {
        ClaudeSession(json: Data("{\"pid\": 42, \(fields)}".utf8))
    }

    @Test func userNamedSessionKeepsItsTitle() {
        let parsed = session(#""status": "idle", "name": "fix-tabs", "nameSource": "user""#)
        #expect(parsed == ClaudeSession(pid: 42, status: .idle, title: "fix-tabs"))
    }

    @Test func derivedNameIsNoTitle() {
        #expect(session(#""status": "busy", "name": "auto", "nameSource": "derived""#)?.title == nil)
    }

    @Test func noStatusIsNoSession() {
        #expect(session(#""name": "x""#) == nil)
        #expect(session(#""status": "sleeping""#) == nil)
    }

    @Test func tabTitleLeadsWithTheMark() {
        let named = ClaudeTab(session: ClaudeSession(pid: 1, status: .waiting, title: "fix-tabs"), account: nil)
        #expect(named.title(fallback: "fish") == "? fix-tabs")
        let unnamed = ClaudeTab(session: ClaudeSession(pid: 1, status: .shell, title: nil), account: nil)
        #expect(unnamed.title(fallback: "fish") == "fish")
    }

    @Test func accountsByExpandedDirFirstRuleWins() {
        let rules = Data("""
        [{"label": "rai", "config_dir": "~/.claude-accounts/reservedai", "color": 34},
         {"label": "dup", "config_dir": "~/.claude-accounts/reservedai", "color": 31},
         {"label": "per", "config_dir": "/abs/personal", "color": "d79921"}]
        """.utf8)
        let accounts = ClaudeAccounts(rules: rules, home: "/Users/me").byDir
        #expect(accounts["/Users/me/.claude-accounts/reservedai"] == ClaudeAccount(label: "rai", color: .systemBlue))
        #expect(accounts["/abs/personal"]?.label == "per")
        #expect(accounts["/abs/personal"]?.color != nil)
    }

    @Test func directoryRoutesToTheFirstMatchingRule() {
        let rules = Data("""
        [{"pattern": "*/repos/_reserved_ai*", "label": "rai", "config_dir": "~/a", "color": 34},
         {"pattern": "*", "label": "per", "config_dir": "~/b", "color": 35}]
        """.utf8)
        let accounts = ClaudeAccounts(rules: rules, home: "/Users/me")
        #expect(accounts.routed("/Users/me/repos/_reserved_ai/reserved-ai/api")?.label == "rai")
        #expect(accounts.routed("/Users/me/repos/claylib")?.label == "per")
        #expect(ClaudeAccounts().routed("/x") == nil)
    }

    @Test func colorsFromAnsiOrHex() {
        #expect(ClaudeAccount.color(of: "35") == .systemPurple)
        #expect(ClaudeAccount.color(of: "#000000") == NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        #expect(ClaudeAccount.color(of: "nope") == nil)
    }

    @Test func ttyOfThisProcess() {
        // The test runner may have no terminal; a dead pid never has one.
        #expect(ClaudeSessions.tty(of: 999_999) == nil)
    }
}

struct ClaudeAttentionTests {
    @Test func stoppingNeedsYou() {
        #expect(ClaudeAttention.justStopped(from: ["a": .busy], to: ["a": .idle]))
        #expect(ClaudeAttention.justStopped(from: ["a": .busy], to: ["a": .waiting]))
        #expect(ClaudeAttention.justStopped(from: ["a": .idle], to: ["a": .waiting]))
    }

    @Test func noChangeOrNewSessionIsQuiet() {
        #expect(!ClaudeAttention.justStopped(from: ["a": .idle], to: ["a": .idle]))
        #expect(!ClaudeAttention.justStopped(from: [:], to: ["a": .waiting]))
        #expect(!ClaudeAttention.justStopped(from: ["a": .idle], to: ["a": .busy]))
        // Answering a choice and then finishing is one stop, already announced.
        #expect(!ClaudeAttention.justStopped(from: ["a": .waiting], to: ["a": .idle]))
    }
}
