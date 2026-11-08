import Foundation

/// One of your open PRs, as claylib's `pr_status.py --json` reports it (the one source of PR
/// status, shared with the Brave PR tab groups).
struct PullRequest: Decodable, Equatable {
    let number: Int
    let title: String
    let url: String
    /// "ready to merge", "CI failing", …
    let status: String
    let icon: String
    /// The branch it merges from.
    let head: String
}

/// Your open PRs in each repo, refreshed at most every two minutes while a terminal in it shows.
@MainActor
final class PullRequests: ObservableObject {
    static let shared = PullRequests()

    @Published private(set) var byRepo: [String: [PullRequest]] = [:]
    private var fetched: [String: Date] = [:]

    private static let script = FileManager.default.homeDirectoryForCurrentUser.path
        + "/repos/claylib/claude/skills/pr-status/pr_status.py"

    /// The open PR from `repo`'s branch.
    func pr(for repo: TabRepo) -> PullRequest? {
        byRepo[repo.name]?.first { $0.head == repo.branch }
    }

    /// Refetches the PRs of the repo checked out in `dir` unless that was under two minutes ago.
    /// shortcut: lists only your own PRs, as pr_status.py does; someone else's branch shows none.
    func refresh(_ repo: TabRepo, dir: String) async {
        guard repo.branch != nil, fetched[repo.name].map({ Date().timeIntervalSince($0) > 120 }) ?? true else { return }
        fetched[repo.name] = Date()
        let script = Self.script
        let output = await Task.detached {
            // An app's PATH lacks Homebrew, where gh lives.
            TabRepo.run("/usr/bin/env", ["PATH=/opt/homebrew/bin:/usr/bin:/bin", "python3", script, "--json"], in: dir)
        }.value
        // A failed run (offline, gh logged out) keeps the last list.
        if let prs = try? JSONDecoder().decode([PullRequest].self, from: Data(output.utf8)) { byRepo[repo.name] = prs }
    }
}
