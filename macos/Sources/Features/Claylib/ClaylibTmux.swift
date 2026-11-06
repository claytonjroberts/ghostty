import Foundation

/// The fork's tmux server (`tmux -L ghostty`, claylib's ghostty/tmux.conf), which Ghostty's
/// `command` starts one session of per tab, so a tab's processes outlive Ghostty's window.
enum ClaylibTmux {
    static let tmux = "/opt/homebrew/bin/tmux"

    /// Runs tmux on the fork's server; "" when it isn't running.
    private static func run(_ args: [String]) -> String {
        TabRepo.run(tmux, ["-L", "ghostty"] + args)
    }

    /// Lines of tab-separated fields.
    private static func rows(_ args: [String]) -> [[String]] {
        run(args).split(separator: "\n").map { $0.components(separatedBy: "\t") }
    }

    /// Each attached tab's terminal (client tty) to the terminal of the pane it shows.
    static func panesByClient() -> [String: String] {
        Dictionary(
            rows(["list-clients", "-F", "#{client_tty}\t#{pane_tty}"]).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil },
            uniquingKeysWith: { first, _ in first })
    }

    /// The terminals of every pane on the server, attached or not.
    static func paneTTYs() -> Set<String> {
        Set(run(["list-panes", "-a", "-F", "#{pane_tty}"]).split(separator: "\n").map(String.init))
    }

    /// Sessions no tab shows, with the directory of their pane, oldest first.
    static func detached() -> [(name: String, dir: String)] {
        rows(["list-sessions", "-F", "#{session_created}\t#{session_name}\t#{session_attached}\t#{pane_current_path}"])
            .filter { $0.count == 4 && $0[2] == "0" }
            .sorted { (Int($0[0]) ?? 0) < (Int($1[0]) ?? 0) }
            .map { ($0[1], $0[3]) }
    }

    /// What a tab runs to show a detached session again.
    static func attach(_ name: String) -> String {
        "\(tmux) -L ghostty attach-session -t '=\(name)'"
    }

    /// Ends the sessions of every terminal in these tabs: what closing a tab means.
    @MainActor
    static func kill(tabs controllers: [BaseTerminalController]) {
        kill(clients: controllers.flatMap { $0.surfaceTree.compactMap { $0.surfaceModel?.ttyName } })
    }

    /// Ends the sessions the given tab terminals show, and everything running in them: what
    /// closing a tab with ⌘W means. Closing the window only detaches.
    static func kill(clients: [String]) {
        let sessions = rows(["list-clients", "-F", "#{client_tty}\t#{session_name}"])
        for row in sessions where row.count == 2 && clients.contains(row[0]) {
            _ = run(["kill-session", "-t", "=" + row[1]])
        }
    }
}
