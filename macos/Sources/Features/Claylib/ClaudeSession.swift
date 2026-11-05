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

    init(pid: pid_t, status: Status, title: String?) {
        self.pid = pid
        self.status = status
        self.title = title
    }

    /// Nil for a file that isn't a session with a status.
    init?(json: Data) {
        guard let file = try? JSONDecoder().decode(File.self, from: json),
              let status = file.status.flatMap(Status.init(rawValue:)) else { return nil }
        let named = file.nameSource != "derived" && !(file.name ?? "").isEmpty
        self.init(pid: file.pid, status: status, title: named ? file.name : nil)
    }

    private struct File: Decodable {
        let pid: pid_t
        let status: String?
        let name: String?
        let nameSource: String?
    }
}

/// A Claude account, from the rules in `~/.config/claude-accounts.yaml`.
struct ClaudeAccount: Equatable {
    let label: String
    let color: NSColor?

    /// The accounts by config dir with `~` expanded, from the rules as JSON (`yq -o json .rules`).
    static func parse(rules: Data, home: String) -> [String: ClaudeAccount] {
        guard let rules = try? JSONDecoder().decode([Rule].self, from: rules) else { return [:] }
        var accounts: [String: ClaudeAccount] = [:]
        for rule in rules {
            let dir = rule.configDir.hasPrefix("~/") ? home + rule.configDir.dropFirst() : rule.configDir
            // The first rule for a dir wins, as it does for the fish helper.
            if accounts[dir] == nil {
                accounts[dir] = ClaudeAccount(label: rule.label, color: rule.color.flatMap(color(of:)))
            }
        }
        return accounts
    }

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

    private struct Rule: Decodable {
        let label: String
        let configDir: String
        let color: String?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            label = try values.decode(String.self, forKey: .label)
            configDir = try values.decode(String.self, forKey: .configDir)
            // The YAML writes ANSI codes as bare numbers.
            color = (try? values.decode(String.self, forKey: .color))
                ?? (try? values.decode(Int.self, forKey: .color)).map(String.init)
        }

        // swiftlint:disable:next nesting
        private enum CodingKeys: String, CodingKey {
            case label, color
            case configDir = "config_dir"
        }
    }
}

/// What a tab shows for the Claude session in its terminal.
struct ClaudeTab: Equatable {
    let session: ClaudeSession
    let account: ClaudeAccount?

    /// The tab's title: the status mark, then the session's title when it has one, else `fallback`.
    func title(fallback: String) -> String {
        let name = session.title ?? fallback
        return session.status.mark.isEmpty ? name : "\(session.status.mark) \(name)"
    }
}
