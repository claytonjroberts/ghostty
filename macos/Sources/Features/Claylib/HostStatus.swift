import Foundation

/// Which machine a terminal is on: this Mac, or the one its foreground `ssh` reached, by its
/// claylib-hosts name (`~/.config/claylib/hosts`) when it's a linked computer.
enum HostStatus {
    private static let hostsFile = FileManager.default.homeDirectoryForCurrentUser.path + "/.config/claylib/hosts"
    static let local = Host.current().localizedName ?? "This Mac"

    /// The machine the shell behind `tty` (a tab's tmux client terminal) is on.
    static func check(tty: String) async -> String {
        await Task.detached {
            let pane = ClaylibTmux.panesByClient()[tty] ?? tty
            let ps = TabRepo.run("/bin/ps", ["-t", (pane as NSString).lastPathComponent, "-o", "stat=,args="])
            return name(ps: ps, hosts: linked()) ?? local
        }.value
    }

    /// Moves the Claude session in the pane a tab's terminal shows to a linked computer, or
    /// `local`, through claylib-claude-tmux; nil when it moved, else what to tell Clayton.
    static func move(tty: String, to host: String) async -> String? {
        await Task.detached {
            guard let pane = ClaylibTmux.paneID(client: tty) else { return "This tab shows no tmux pane." }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // An app's PATH lacks Homebrew and ~/.local/bin, where tmux and claylib live.
            process.arguments = [
                "PATH=\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                "claylib-claude-tmux", "--pane", pane, "--to", host,
            ]
            let err = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = err
            guard (try? process.run()) != nil else { return "claylib-claude-tmux didn't start." }
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()  // off the main thread, so safe here
            return failure(status: process.terminationStatus, stderr: stderr)
        }.value
    }

    /// claylib-claude-tmux's exit status and stderr as Clayton's message; nil for 0, moved.
    static func failure(status: Int32, stderr: String) -> String? {
        switch status {
        case 0: nil
        case 3: "The session stopped and couldn't be resumed anywhere. Resume it yourself:\n\n\(stderr)"
        default: stderr.isEmpty ? "The move failed (exit \(status)); the session is where it was." : stderr
        }
    }

    /// The linked computers, as name and ssh destination.
    static func linked() -> [(String, String)] {
        ((try? String(contentsOfFile: hostsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ").map(String.init)
                return fields.count == 2 ? (fields[0], fields[1]) : nil
            }
    }

    /// How a linked computer's name reads: "mothership" as "Mothership".
    static func display(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

    /// The host of the foreground `ssh` in `ps -o stat=,args=` output, named as in `hosts`
    /// (name, destination pairs) when it matches one; nil when no ssh runs in the foreground.
    static func name(ps: String, hosts: [(String, String)]) -> String? {
        for line in ps.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            // "+" in stat: the terminal's foreground process group.
            guard fields.count > 1, fields[0].contains("+"),
                  (fields[1] as NSString).lastPathComponent == "ssh",
                  let dest = destination(Array(fields.dropFirst(2))) else { continue }
            let host = dest.split(separator: "@").last.map(String.init) ?? dest
            // An ssh config alias may share the linked name.
            return hosts.first { $0.0 == dest || $0.1 == dest || $0.1.split(separator: "@").last.map(String.init) == host }
                .map { display($0.0) } ?? host
        }
        return nil
    }

    /// ssh's destination: its first argument that is neither an option nor an option's value.
    private static func destination(_ args: [String]) -> String? {
        var skip = false
        for arg in args {
            if skip { skip = false; continue }
            guard arg.hasPrefix("-") else { return arg }
            // Options that take a value, when it isn't attached (`-p 22`, not `-p22`).
            if arg.count == 2, "BbcDEeFIiJLlmOopQRSWw".contains(arg.last!) { skip = true }
        }
        return nil
    }
}
