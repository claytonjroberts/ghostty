import AppKit

/// A Claude Code session, from one file of Claude's session registry
/// (`<config dir>/sessions/<pid>.json`).
struct ClaudeSession: Equatable {
    enum Status: String {
        case busy, idle, waiting, shell

        /// ? waiting on a choice, ✓ done and waiting on you, ↻ working.
        var mark: String {
            switch self {
            case .waiting: "?"
            case .idle: "✓"
            case .busy: "↻"
            case .shell: ""
            }
        }
    }

    let pid: pid_t
    let status: Status
    /// The session's name when the user set it; nil when Claude derived it.
    let title: String?
    /// What `claude --resume` takes.
    let id: String?
    let cwd: String?

    init(pid: pid_t, status: Status, title: String?, id: String? = nil, cwd: String? = nil) {
        self.pid = pid
        self.status = status
        self.title = title
        self.id = id
        self.cwd = cwd
    }

    /// Nil for a file that isn't a session with a status.
    init?(json: Data) {
        guard let file = try? JSONDecoder().decode(File.self, from: json),
              let status = file.status.flatMap(Status.init(rawValue:)) else { return nil }
        let named = file.nameSource != "derived" && !(file.name ?? "").isEmpty
        self.init(pid: file.pid, status: status, title: named ? file.name : nil, id: file.sessionId, cwd: file.cwd)
    }

    private struct File: Decodable {
        let pid: pid_t
        let status: String?
        let name: String?
        let nameSource: String?
        let sessionId: String?
        let cwd: String?
    }
}

/// A Claude account, from the rules in `~/.config/claude-accounts.yaml`.
/// The accounts in ~/.config/claude-accounts.yaml, from its rules as JSON (`yq -o json .rules`).
struct ClaudeAccounts: Equatable {
    /// By config dir with `~` expanded; the first rule for a dir wins, as it does for fish.
    private(set) var byDir: [String: ClaudeAccount] = [:]
    private var routes: [(pattern: String, account: ClaudeAccount)] = []

    init() {}

    init(rules: Data, home: String) {
        guard let rules = try? JSONDecoder().decode([ClaudeAccount.Rule].self, from: rules) else { return }
        for rule in rules {
            let account = ClaudeAccount(label: rule.label, color: rule.color.flatMap(ClaudeAccount.color(of:)))
            let dir = rule.configDir.hasPrefix("~/") ? home + rule.configDir.dropFirst() : rule.configDir
            if byDir[dir] == nil { byDir[dir] = account }
            if let pattern = rule.pattern { routes.append((pattern, account)) }
        }
    }

    /// The account `claude` started in `dir` bills to: the first rule whose glob matches, as
    /// fish's `claude-account` routes it. A shell pinned to another account isn't seen here.
    func routed(_ dir: String) -> ClaudeAccount? {
        routes.first { fnmatch($0.pattern, dir, 0) == 0 }?.account
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.byDir == rhs.byDir && lhs.routes.elementsEqual(rhs.routes) { $0.pattern == $1.pattern && $0.account == $1.account }
    }
}

struct ClaudeAccount: Equatable {
    let label: String
    let color: NSColor?

    /// An ANSI foreground code (31-36) or a hex color.
    static func color(of value: String) -> NSColor? {
        switch value {
        case "31": return .systemRed
        case "32": return .systemGreen
        case "33": return .systemYellow
        case "34": return .systemBlue
        case "35": return .systemPurple
        case "36": return .systemTeal
        default:
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
            return NSColor(
                srgbRed: CGFloat(rgb >> 16 & 0xff) / 255,
                green: CGFloat(rgb >> 8 & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255,
                alpha: 1)
        }
    }

    fileprivate struct Rule: Decodable {
        let pattern: String?
        let label: String
        let configDir: String
        let color: String?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            pattern = try? values.decode(String.self, forKey: .pattern)
            label = try values.decode(String.self, forKey: .label)
            configDir = try values.decode(String.self, forKey: .configDir)
            // The YAML writes ANSI codes as bare numbers.
            color = (try? values.decode(String.self, forKey: .color))
                ?? (try? values.decode(Int.self, forKey: .color)).map(String.init)
        }

        // swiftlint:disable:next nesting
        private enum CodingKeys: String, CodingKey {
            case pattern, label, color
            case configDir = "config_dir"
        }
    }
}

/// What a tab shows for the Claude session in its terminal.
struct ClaudeTab: Equatable {
    let session: ClaudeSession
    let account: ClaudeAccount?
    /// The Claude config dir whose registry lists the session: its account.
    let configDir: String?
    /// The color picked with `/color`; nil when none was.
    var color: NSColor?

    /// The last `/color` in a transcript's text: Claude appends `{"type":"agent-color",...}`.
    static func agentColor(transcript: Substring) -> NSColor? {
        let record = transcript.split(separator: "\n").last { $0.contains(#""type":"agent-color""#) }
        struct Record: Decodable { let agentColor: String }
        guard let record, let name = try? JSONDecoder().decode(Record.self, from: Data(record.utf8)).agentColor
        else { return nil }
        return [
            "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow, "green": .systemGreen,
            "cyan": .systemCyan, "blue": .systemBlue, "purple": .systemPurple, "pink": .systemPink,
        ][name]
    }

    /// What a shell types to resume the session under its account.
    var resume: String? {
        guard let id = session.id, let configDir else { return nil }
        return "env CLAUDE_CONFIG_DIR='\(configDir)' claude --resume \(id)\n"
    }

    /// The session's title when it has one, else `fallback`.
    func name(fallback: String) -> String { session.title ?? fallback }

    /// The window title: the status mark, then the name.
    func title(fallback: String) -> String {
        let name = name(fallback: fallback)
        return session.status.mark.isEmpty ? name : "\(session.status.mark) \(name)"
    }
}
