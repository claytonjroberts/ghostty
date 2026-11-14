import AppKit
import Foundation

/// One task file from agent-dispatcher's human-task folder: something a Claude session needs
/// Clayton to do, or a question that can wait. agent_dispatcher/human_tasks.py owns the format.
struct HumanTask: Decodable, Identifiable, Equatable {
    enum Kind: String, Decodable { case action, question }

    let id: String
    let title: String
    let created: Double
    /// Optional fields are absent from files written before they existed.
    private let kindValue: Kind?
    private let commandValue: String?
    let host: String?
    private let optionsValue: [String]?
    private let answerValue: String?
    let doneAt: Double?
    /// Set once Run's command ends; `output` is what it printed, for the session that asked too.
    let exitStatus: Int?
    private let outputValue: String?
    private let requesterValue: String?
    private let detailsValue: String?
    private let blockingValue: Bool?
    private let noteValue: String?
    private let rejectionValue: String?

    var kind: Kind { kindValue ?? .action }
    var command: String { commandValue ?? "" }
    var options: [String] { optionsValue ?? [] }
    var answer: String { answerValue ?? "" }
    var done: Bool { doneAt != nil }
    var output: String { outputValue ?? "" }
    /// The Claude session that asked.
    var requester: String { requesterValue ?? "" }
    var details: String { detailsValue ?? "" }
    /// The asking session is stopped until this is done; otherwise it's optional.
    var blocking: Bool { blockingValue ?? false }
    /// Tasks from before `blocking` existed say neither.
    var saysIfBlocking: Bool { blockingValue != nil }
    /// What Clayton told the asking session, typically about a run.
    var note: String { noteValue ?? "" }
    /// Why Clayton declined it; such a task is also done.
    var rejection: String { rejectionValue ?? "" }

    func outputTail(lines: Int) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, created, host
        case kindValue = "kind", commandValue = "command", optionsValue = "options", answerValue = "answer"
        case doneAt = "done_at", exitStatus = "exit_status", outputValue = "output"
        case requesterValue = "requester", detailsValue = "details", blockingValue = "blocking", noteValue = "note", rejectionValue = "rejection"
    }

    /// The tasks in these files, blockers first, then oldest first; a file that doesn't parse is skipped.
    static func parse(_ files: [Data]) -> [HumanTask] {
        files.compactMap { try? JSONDecoder().decode(HumanTask.self, from: $0) }
            .sorted { ($0.blocking ? 0 : 1, $0.created) < ($1.blocking ? 0 : 1, $1.created) }
    }
}

/// The human-task folder, kept current by watching it. Changes go through agent-dispatcher's
/// `human-task` CLI, so the fork never writes the format or reimplements the 72-hour prune.
@MainActor
final class HumanTasks: ObservableObject {
    static let shared = HumanTasks()

    @Published private(set) var tasks: [HumanTask] = []

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Mirrors TASKS_DIR in agent_dispatcher/human_tasks.py.
    static let dir = home + "/.local/state/agent-dispatcher/human-tasks"
    private var watcher: FileWatcher?

    private init() {
        // FSEvents can't watch a folder that doesn't exist yet.
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        reload()
        watcher = FileWatcher(paths: [Self.dir]) { [weak self] _ in self?.reload() }
    }

    var openActions: [HumanTask] { tasks.filter { !$0.done && $0.kind == .action } }
    var openQuestions: [HumanTask] { tasks.filter { !$0.done && $0.kind == .question } }
    var finished: [HumanTask] { tasks.filter(\.done) }

    private func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.dir)) ?? []
        let files = names.filter { $0.hasSuffix(".json") }.compactMap { FileManager.default.contents(atPath: Self.dir + "/" + $0) }
        let parsed = HumanTask.parse(files)
        if parsed != tasks { tasks = parsed }
    }

    /// Runs `human-task <args>` off the main thread; its stdout.
    private nonisolated static func cli(_ args: [String]) async -> String {
        await Task.detached {
            TabRepo.run(
                "/opt/homebrew/bin/uv",
                ["run", "--quiet", "--directory", home + "/repos/agent-dispatcher", "human-task"] + args)
        }.value
    }

    /// Clayton looked at the list: what the 72-hour prune counts as having seen a task.
    func visit() { Task { _ = await Self.cli(["visit"]) } }
    func done(_ task: HumanTask) { Task { _ = await Self.cli(["done", task.id]) } }
    func reopen(_ task: HumanTask) { Task { _ = await Self.cli(["reopen", task.id]) } }
    func answer(_ task: HumanTask, _ text: String) { Task { _ = await Self.cli(["answer", task.id, text]) } }
    func note(_ task: HumanTask, _ text: String) { Task { _ = await Self.cli(["note", task.id, text]) } }
    func reject(_ task: HumanTask, _ reason: String) { Task { _ = await Self.cli(["reject", task.id, reason]) } }

    /// Starts the task's command in its own tmux session and opens a tab attached to it.
    func run(_ task: HumanTask) {
        Task {
            let session = await Self.cli(["start", task.id]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !session.isEmpty, let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else {
                NSSound.beep()
                return
            }
            var config = Ghostty.SurfaceConfiguration()
            config.command = ClaylibTmux.attach(session)
            let parent = NSApp.orderedWindows.first { $0 is TerminalWindow }
            let window = TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)?.window
            Self.adopt(window)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The tmux sessions `human-task start` makes are `task-<id>` (start_session in human_tasks.py).
    nonisolated static func isTaskSession(_ name: String) -> Bool { name.hasPrefix("task-") }

    /// Puts a task's tab in the human tasks tab group, beside the other task tabs.
    static func adopt(_ window: NSWindow?) {
        guard let window = window as? TerminalWindow else { return }
        window.tabRepo = .humanTasks
        TabGrouping.regroup(window)
    }
}

/// Opens `claylib-task://run/<id>`, the dispatcher web UI's "Open in terminal", as the task's Run:
/// the link names only a task, so what runs is that task's stored command, in a visible tab.
final class HumanTaskLinks: NSObject {
    static let shared = HumanTaskLinks()

    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(open(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func open(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let id = Self.taskID(event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue) else { return }
        MainActor.assumeIsolated {
            guard let task = HumanTasks.shared.tasks.first(where: { $0.id == id }), !task.command.isEmpty else {
                NSSound.beep()
                return
            }
            HumanTasks.shared.run(task)
        }
    }

    /// The task id in a `claylib-task://run/<id>` link; nil for anything else.
    static func taskID(_ link: String?) -> String? {
        guard let url = link.flatMap(URL.init(string:)), url.scheme == "claylib-task", url.host == "run",
              url.pathComponents.count == 2 else { return nil }
        return url.pathComponents[1]
    }
}
