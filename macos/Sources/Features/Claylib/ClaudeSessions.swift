import Darwin
import Foundation

/// Every live Claude Code session on this machine by the tty it runs in. Kept current by
/// watching Claude's session registries and the accounts file, so nothing polls.
@MainActor
final class ClaudeSessions: ObservableObject {
    static let shared = ClaudeSessions()

    @Published private(set) var byTTY: [String: ClaudeTab] = [:]

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private var accounts: [String: ClaudeAccount] = [:]
    private var watcher: FileWatcher?

    private init() {
        loadAccounts()
        reload()
        watcher = FileWatcher(paths: configDirs.map { $0 + "/sessions" } + [home + "/.config"]) { [weak self] paths in
            self?.changed(paths)
        }
    }

    /// Claude's config dirs: `~/.claude` and each account under `~/.claude-accounts`.
    /// shortcut: an account dir added while Ghostty runs is seen only after a restart.
    private lazy var configDirs: [String] = {
        let root = home + "/.claude-accounts"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return [home + "/.claude"] + names.sorted().map { root + "/" + $0 }
    }()

    private var accountsFile: String { home + "/.config/claude-accounts.yaml" }

    private func reload() {
        var tabs: [String: ClaudeTab] = [:]
        for dir in configDirs {
            let sessions = dir + "/sessions"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions)) ?? []
            for name in names.sorted() where name.hasSuffix(".json") {
                // A file left behind by a session that died has no live pid, so no tty.
                guard let data = FileManager.default.contents(atPath: sessions + "/" + name),
                      let session = ClaudeSession(json: data),
                      let tty = Self.tty(of: session.pid),
                      tabs[tty] == nil else { continue }
                tabs[tty] = ClaudeTab(session: session, account: accounts[dir])
            }
        }
        if tabs != byTTY { byTTY = tabs }
    }

    /// Reads the YAML through `yq`, which claylib already depends on.
    private func loadAccounts() {
        let candidates = ["/opt/homebrew/bin/yq", "/usr/local/bin/yq"]
        guard let yq = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: yq)
        process.arguments = ["-o", "json", ".rules", accountsFile]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let rules = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        accounts = ClaudeAccount.parse(rules: rules, home: home)
    }

    private func changed(_ paths: [String]) {
        if paths.contains(accountsFile) { loadAccounts() }
        if paths.contains(where: { $0.contains("/sessions/") || $0 == accountsFile }) { reload() }
    }

    /// The controlling terminal of a process as `/dev/ttysNNN`; nil when it is gone or has none.
    nonisolated static func tty(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.e_tdev != UInt32.max,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}
