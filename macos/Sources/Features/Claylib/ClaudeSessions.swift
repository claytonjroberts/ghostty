import Darwin
import Foundation

/// Every live Claude Code session on this machine by the tty it runs in. Kept current by
/// watching Claude's session registries and the accounts file, so nothing polls.
@MainActor
final class ClaudeSessions: ObservableObject {
    static let shared = ClaudeSessions()

    @Published private(set) var byTTY: [String: ClaudeTab] = [:]
    @Published private(set) var accounts = ClaudeAccounts()

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
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
                tabs[tty] = ClaudeTab(
                    session: session, account: accounts.byDir[dir], configDir: dir,
                    color: Self.transcriptTail(dir: dir, session: session).flatMap(ClaudeTab.agentColor(transcript:)))
            }
        }
        if tabs != byTTY { byTTY = tabs }
    }

    /// The last 512 KB of a session's transcript, `<config dir>/projects/<cwd, non-alphanumerics
    /// as ->/<id>.jsonl`.
    /// shortcut: a `/color` further back than that is missed; Claude re-appends it often.
    private static func transcriptTail(dir: String, session: ClaudeSession) -> Substring? {
        guard let id = session.id, let cwd = session.cwd else { return nil }
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        guard let file = FileHandle(forReadingAtPath: "\(dir)/projects/\(folder)/\(id).jsonl") else { return nil }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        return (try? file.readToEnd()).map { Substring(String(decoding: $0, as: UTF8.self)) }
    }

    private func loadAccounts() { accounts = Self.readAccounts(accountsFile, home: home) }

    /// Reads the YAML through `yq`, which claylib already depends on. Never `waitUntilExit`: it
    /// turns the run loop, and a SwiftUI update in that turn reaching `shared` mid-init traps.
    static func readAccounts(_ file: String, home: String) -> ClaudeAccounts {
        let candidates = ["/opt/homebrew/bin/yq", "/usr/local/bin/yq"]
        guard let yq = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return ClaudeAccounts() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: yq)
        process.arguments = ["-o", "json", ".rules", file]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ClaudeAccounts() }
        return ClaudeAccounts(rules: out.fileHandleForReading.readDataToEndOfFile(), home: home)
    }

    /// The account a terminal bills to: its Claude session's, else the one its directory routes to.
    func account(tty: String?, dir: String?) -> ClaudeAccount? {
        tty.flatMap { byTTY[$0] }?.account ?? dir.flatMap(accounts.routed)
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
