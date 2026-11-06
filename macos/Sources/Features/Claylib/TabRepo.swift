import AppKit

/// The repo a tab's directory is in, from claylib's `claylib-tab-color` (the one source of the
/// directory to repo and color mapping), and the branch checked out there.
struct TabRepo: Equatable {
    /// "" outside a repo.
    let name: String
    let color: NSColor?
    let branch: String?

    /// Parses `claylib-tab-color --dir <dir> --meta`: `<RRGGBB or default>\t<repo>\t<worktree>`.
    init(meta: String, branch: String?) {
        let fields = meta.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        name = fields.count > 1 ? fields[1] : ""
        color = fields.first.flatMap(ClaudeAccount.color(of:))
        self.branch = branch.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static var cache: [String: TabRepo] = [:]
    private static let script = FileManager.default.homeDirectoryForCurrentUser.path
        + "/repos/claylib/src_terminal_helpers/claylib-tab-color"

    /// Looked up off the main thread; cached per directory.
    /// shortcut: a branch switched in a directory already seen keeps its old name until restart.
    @MainActor
    static func lookup(_ dir: String) async -> TabRepo {
        if let known = cache[dir] { return known }
        let repo = await Task.detached {
            TabRepo(
                meta: run(script, ["--dir", dir, "--meta"]),
                branch: run("/usr/bin/git", ["-C", dir, "branch", "--show-current"])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        cache[dir] = repo
        return repo
    }

    /// Stdout of a program, "" when it can't start. Blocks until the program closes its output.
    /// Never `waitUntilExit`: it turns the run loop, and on the main thread a SwiftUI update in
    /// that turn can reach a singleton mid-init, which traps.
    static func run(_ path: String, _ args: [String], in dir: String? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = dir.map { URL(fileURLWithPath: $0) }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        return String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

/// Keeps each repo's tabs side by side in a window's tab group.
enum TabGrouping {
    /// Where the tab at `moving` should go so its repo's tabs are together: after the index this
    /// returns. Nil when they already are, or when it is its repo's only tab.
    static func anchor(repos: [String?], moving: Int) -> Int? {
        guard let repo = repos[moving] else { return nil }
        let same = repos.indices.filter { repos[$0] == repo }
        guard let first = same.first, let last = same.last, last - first + 1 != same.count else { return nil }
        return same.last { $0 != moving }
    }

    /// Moves `window` beside the other tabs of its repo.
    @MainActor
    static func regroup(_ window: TerminalWindow) {
        guard let group = window.tabGroup else { return }
        let windows = group.windows
        guard let moving = windows.firstIndex(of: window),
              let anchor = anchor(repos: windows.map { ($0 as? TerminalWindow)?.tabRepo?.name }, moving: moving)
        else { return }
        let wasKey = window.isKeyWindow
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        group.removeWindow(window)
        windows[anchor].addTabbedWindowSafely(window, ordered: .above)
        if wasKey { window.makeKey() }
        NSAnimationContext.endGrouping()
    }
}
