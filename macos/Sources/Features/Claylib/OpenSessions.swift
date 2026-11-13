import AppKit
import Combine

/// A Claude session open in a Ghostty tab, kept so it can be reopened after Ghostty quits.
struct OpenSession: Codable, Equatable {
    let id: String
    let cwd: String
    /// The account's Claude config dir.
    let configDir: String

    /// What a shell types to resume it under its account. It goes to the session's directory
    /// first: Claude finds a session by it.
    var resume: String { "cd '\(cwd)' && env CLAUDE_CONFIG_DIR='\(configDir)' claude --resume \(id)\n" }

    /// The list to keep: saved sessions, unless seen to end this run, then newly live ones.
    /// A session seen live here and now gone was closed or exited, so it's dropped; one never seen
    /// this run is waiting to be reopened, so it stays.
    static func kept(saved: [OpenSession], live: [OpenSession], seen: Set<String>) -> [OpenSession] {
        let liveIDs = Set(live.map(\.id))
        let savedIDs = Set(saved.map(\.id))
        return saved.filter { liveIDs.contains($0.id) || !seen.contains($0.id) }
            + live.filter { !savedIDs.contains($0.id) }
    }
}

/// The Claude sessions open in Ghostty's tabs, kept in a file so that launching Ghostty, or
/// Restore Claude Sessions in the menu bar menu, reopens each one that isn't running in a tab of
/// its own. Quitting keeps the list; closing a tab or exiting Claude drops that session.
@MainActor
final class OpenSessions {
    static let shared = OpenSessions()

    private(set) var saved: [OpenSession] = []
    /// Live in a Ghostty tab at some point this run.
    private var seen: Set<String> = []
    /// Reopened this run; not reopened again while they start up.
    private var reopened: [String: Date] = [:]
    private var terminating = false
    private var cancellables: Set<AnyCancellable> = []

    private let file: String = {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.local/state"
        return state + "/claylib/ghostty-sessions.json"
    }()

    func install() {
        saved = (try? JSONDecoder().decode([OpenSession].self, from: Data(contentsOf: URL(fileURLWithPath: file)))) ?? []
        // Quitting ends every session; that isn't closing them.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.terminating = true }.store(in: &cancellables)
        ClaudeSessions.shared.$byTTY.sink { [weak self] in self?.update($0) }.store(in: &cancellables)
        // Once Ghostty's first window is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reopen() }
    }

    /// The terminals of every Ghostty tab and split, by tty.
    static var ttys: Set<String> {
        Set(NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .flatMap { $0.surfaceTree.compactMap { $0.surfaceModel?.ttyName } })
    }

    /// Saved sessions not running anywhere, nor reopened in the last minute.
    var missing: [OpenSession] {
        let live = Set(ClaudeSessions.shared.byTTY.values.compactMap(\.session.id))
        return saved.filter { !live.contains($0.id) && (reopened[$0.id].map { -$0.timeIntervalSinceNow > 60 } ?? true) }
    }

    /// What Restore would bring back: detached tmux sessions and missing Claude sessions.
    var restorable: Int { ClaylibTmux.detached().count + missing.count }

    /// Reattaches a tab to each detached tmux session, then opens one resuming each Claude session
    /// not running anywhere (its tmux server ended, as on a reboot), after the frontmost terminal's
    /// tabs. Opens a window when none is left, as Ghostty opens none itself at launch.
    func reopen() {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var parent = NSApp.orderedWindows.first { $0 is TerminalWindow }
        @discardableResult
        func open(_ config: Ghostty.SurfaceConfiguration) -> TerminalController? {
            let controller = TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)
            parent = controller?.window ?? parent
            return controller
        }
        for session in ClaylibTmux.detached() {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = session.dir
            config.command = ClaylibTmux.attach(session.name)
            // Its shell reports a directory only on cd; the tab needs it now, for its repo.
            let controller = open(config)
            controller?.surfaceTree.forEach { $0.pwd = session.dir }
            if HumanTasks.isTaskSession(session.name) { HumanTasks.adopt(controller?.window) }
        }
        for session in missing {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = session.cwd
            config.initialInput = session.resume
            reopened[session.id] = Date()
            open(config)
        }
        if parent == nil { open(Ghostty.SurfaceConfiguration()) }
        // Attaching changes no registry file, so the tabs learn their Claude sessions from this.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ClaudeSessions.shared.reload() }
    }

    private func update(_ byTTY: [String: ClaudeTab]) {
        guard !terminating else { return }
        let here = Self.ttys
        let live = byTTY.filter { here.contains($0.key) }.compactMap(\.value.open)
        seen.formUnion(live.map(\.id))
        let next = OpenSession.kept(saved: saved, live: live, seen: seen)
        guard next != saved else { return }
        saved = next
        try? FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONEncoder().encode(next).write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}
