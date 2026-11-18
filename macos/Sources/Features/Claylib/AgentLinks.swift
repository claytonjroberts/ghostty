import AppKit
import Foundation

/// Opens `claylib-task://attach/<agent>`, the dispatcher web UI's Connect: a tab attached to that
/// agent's tmux session, wherever the router says it runs.
final class AgentLinks: NSObject {
    static let shared = AgentLinks()

    /// The deployed summoner checkout whose `human-task attach` CLI asks the router.
    static let project = FileManager.default.homeDirectoryForCurrentUser.path + "/repos/summoner-deploy"

    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(open(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func open(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let agent = Self.agent(event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue) else { return }
        MainActor.assumeIsolated { Task {
            let command = await Task.detached {
                TabRepo.run("/opt/homebrew/bin/uv", ["run", "--quiet", "--directory", Self.project, "human-task", "attach", agent])
            }.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else {
                NSSound.beep()
                return
            }
            var config = Ghostty.SurfaceConfiguration()
            config.command = command
            let parent = NSApp.orderedWindows.first { $0 is TerminalWindow }
            TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } }
    }

    /// The agent a link names; nil for anything else, as what runs comes from the router.
    static func agent(_ link: String?) -> String? {
        guard let url = link.flatMap(URL.init(string:)), url.scheme == "claylib-task", url.host == "attach",
              url.pathComponents.count == 2 else { return nil }
        let name = url.pathComponents[1]
        return name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? name : nil
    }
}
