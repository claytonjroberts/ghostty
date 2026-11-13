import AppKit

/// The repo a tab's directory is in, from claylib's `claylib-tab-color` (the one source of the
/// directory to repo and color mapping), and the branch checked out there.
struct TabRepo: Equatable {
    /// `home` in the home directory, "" in any other directory outside a repo.
    let name: String
    let color: NSColor?
    let branch: String?

    /// The home directory's group, drawn with a house.
    static let home = "~/"

    /// The group of tabs running human tasks (HumanTasks), drawn with a flag. A tab in it keeps it
    /// whatever directory its terminal reports.
    static let humanTasks = TabRepo(name: "human tasks", color: .systemOrange)

    private init(name: String, color: NSColor?) {
        self.name = name
        self.color = color
        branch = nil
    }

    /// Parses `claylib-tab-color --dir <dir> --meta`: `<RRGGBB or default>\t<repo>\t<worktree>`.
    init(meta: String, branch: String?, dir: String) {
        let fields = meta.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        name = dir == NSHomeDirectory() ? Self.home : fields.count > 1 ? fields[1] : ""
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
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                dir: dir)
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
        move([window], beside: windows[anchor], before: false)
    }

    /// Where tabs dragged onto others land: before the target when they come from its right,
    /// after it when they come from its left. Nil when there's nowhere to go (dropped on themselves).
    static func drop<T: Equatable>(order: [T], moving: [T], onto target: [T]) -> (anchor: T, before: Bool)? {
        let target = target.filter { !moving.contains($0) }
        guard let first = target.first, let last = target.last,
              let from = moving.first.flatMap(order.firstIndex(of:)),
              let to = order.firstIndex(of: first) else { return nil }
        return from > to ? (first, true) : (last, false)
    }

    /// Moves tabs, keeping their order, next to `anchor` in its window's tab group; the selected
    /// tab stays selected.
    @MainActor
    static func move(_ moving: [NSWindow], beside anchor: NSWindow, before: Bool) {
        guard let group = anchor.tabGroup else { return }
        let selected = group.selectedWindow
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        var previous: NSWindow?
        for window in moving {
            group.removeWindow(window)
            if let previous {
                previous.addTabbedWindowSafely(window, ordered: .above)
            } else {
                anchor.addTabbedWindowSafely(window, ordered: before ? .below : .above)
            }
            previous = window
        }
        group.selectedWindow = selected
        selected?.makeKey()
        NSAnimationContext.endGrouping()
        ClaylibTabs.shared.changed()
    }
}
