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
            let hosts = ((try? String(contentsOfFile: hostsFile, encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { line -> (String, String)? in
                    let fields = line.split(separator: " ").map(String.init)
                    return fields.count == 2 ? (fields[0], fields[1]) : nil
                }
            return name(ps: ps, hosts: hosts) ?? local
        }.value
    }

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
            return hosts.first { $0.1 == dest || $0.1.split(separator: "@").last.map(String.init) == host }
                .map { $0.0.prefix(1).uppercased() + $0.0.dropFirst() } ?? host
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
