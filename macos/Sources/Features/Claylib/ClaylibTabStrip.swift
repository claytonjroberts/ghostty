import SwiftUI

/// Bumped whenever anything a tab strip draws changes (a tab's title, repo, Claude session,
/// key or selection), so every window's strip redraws from its tab group.
@MainActor
final class ClaylibTabs: ObservableObject {
    static let shared = ClaylibTabs()
    @Published private(set) var revision = 0
    private var pending = false

    /// Published on the next run loop turn, once per burst: changes arrive inside AppKit's
    /// layout (a restored tab made key), and redrawing the strip mid-pass makes AppKit throw.
    func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            self.pending = false
            self.revision &+= 1
        }
    }
}

/// One tab as the strip draws it.
struct StripTab: Equatable {
    let window: NSWindow
    /// "" outside a repo, drawn as "other".
    let repo: String
    let color: NSColor?
    let account: ClaudeAccount?
    let status: ClaudeSession.Status?
    /// The Claude session's `/color`, outlining the tab.
    let outline: NSColor?
    let name: String
    let key: String
    let active: Bool

    @MainActor
    init(window: NSWindow) {
        let terminal = window as? TerminalWindow
        let surface = (window.windowController as? BaseTerminalController)?.focusedSurface
        self.window = window
        repo = terminal?.tabRepo?.name ?? ""
        color = terminal?.tabRepo?.color
        account = ClaudeSessions.shared.account(tty: surface?.surfaceModel?.ttyName, dir: surface?.pwd)
        status = terminal?.claudeTab?.session.status
        outline = terminal?.claudeTab?.color
        name = terminal?.tabName.isEmpty == false ? terminal?.tabName ?? "" : window.title
        key = terminal?.keyEquivalent ?? ""
        active = window.tabGroup?.selectedWindow === window
    }
}

/// Runs of neighbors with the same key; TabGrouping keeps each repo's tabs together, so runs of
/// tabs by repo are the repo groups.
func runs<T>(_ items: [T], by key: (T) -> String) -> [[T]] {
    items.reduce(into: []) { runs, item in
        if let last = runs.last?.first, key(last) == key(item) { runs[runs.count - 1].append(item) } else { runs.append([item]) }
    }
}

/// Claylib: the window's tabs in place of the native tab bar (hidden by TerminalWindow), grouped
/// Safari style: each repo's label in its color, then its tabs underlined in that color. The
/// selected tab is filled with that color. A tab shows its Claude status and its name, with its
/// key and billing account in its tooltip; a tab running Claude is
/// outlined in its /color. The + after a group opens a tab beside it, in its directory, running
/// Claude. Tabs wrap onto another row past `perRow`. Dragging a tab reorders it within its group;
/// dragging a group's label moves the whole group.
struct ClaylibTabStrip: View {
    /// Any terminal in the window; its window is read on every redraw, as tabs move between windows.
    let surface: Ghostty.SurfaceView?
    let background: Color

    @ObservedObject private var tabs = ClaylibTabs.shared
    @ObservedObject private var sessions = ClaudeSessions.shared

    /// Tabs on one line of the strip; past that they wrap onto another.
    static let perRow = 6

    var body: some View {
        let windows = surface?.window.map { $0.tabGroup?.windows ?? [$0] } ?? []
        let all = windows.map(StripTab.init(window:))
        let groups = runs(all, by: \.repo).map { $0.map(\.window) }
        let rows = stride(from: 0, to: all.count, by: Self.perRow).map { Array(all[$0..<min($0 + Self.perRow, all.count)]) }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.indices, id: \.self) { row in
                // Tabs are direct children of one stack, so they share its width evenly. A group
                // that wraps shows its label again on the next row.
                HStack(spacing: 1) {
                    ForEach(Array(runs(rows[row], by: \.repo).enumerated()), id: \.offset) { index, piece in
                        let group = groups.first { $0.contains(piece[0].window) } ?? piece.map(\.window)
                        let color = Color(piece[0].color ?? .systemGray)
                        GroupLabel(repo: piece[0].repo, color: piece[0].color ?? .systemGray)
                            .onDrag { NSItemProvider(object: Self.payload("group", group) as NSString) }
                            .modifier(DropTarget { drop($0, onto: group, group: group, order: windows) })
                            .padding(.leading, index == 0 ? 0 : 6)
                            .padding(.trailing, 4)
                        ForEach(Array(piece.enumerated()), id: \.offset) { _, tab in
                            TabView(tab: tab, color: color)
                                .onDrag { NSItemProvider(object: Self.payload("tab", [tab.window]) as NSString) }
                                .modifier(DropTarget { drop($0, onto: [tab.window], group: group, order: windows) })
                        }
                        Button {
                            let last = piece[piece.count - 1].window
                            newTab(from: last, in: (last.windowController as? BaseTerminalController)?.focusedSurface?.pwd, running: "claude\n")
                        } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New tab in \(piece[0].repo.isEmpty ? "this directory" : piece[0].repo), running Claude")
                    }
                    Spacer(minLength: 0)
                    if row == 0 { trailingButtons(windows) }
                }
            }
            if rows.isEmpty { HStack { Spacer(minLength: 0); trailingButtons(windows) } }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .bottomLeading)
        .background(Color(strip))
        .id(tabs.revision)
    }

    /// What a drag carries: `tab:` or `group:` and the window numbers of the tabs it moves.
    private static func payload(_ kind: String, _ windows: [NSWindow]) -> String {
        kind + ":" + windows.map { String($0.windowNumber) }.joined(separator: ",")
    }

    /// Moves the dragged tabs next to `target`. A group moves next to the target's whole group; a
    /// tab moves only within its own, as a tab's repo decides its group.
    private func drop(_ payload: String, onto target: [NSWindow], group: [NSWindow], order: [NSWindow]) {
        let parts = payload.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let moving = parts[1].split(separator: ",").compactMap { Int($0).flatMap(NSApp.window(withWindowNumber:)) }
        let onto = parts[0] == "group" ? group : target
        guard parts[0] == "group" || moving.allSatisfy(group.contains),
              let (anchor, before) = TabGrouping.drop(order: order, moving: moving, onto: onto) else { return }
        TabGrouping.move(moving, beside: anchor, before: before)
    }

    @ViewBuilder
    private func trailingButtons(_ windows: [NSWindow]) -> some View {
        if let last = windows.last {
            let away = sessionsElsewhere
            if !away.isEmpty {
                Button { bringHere(away, beside: last) } label: {
                    Label("\(away.count)", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Bring \(away.count) idle Claude session\(away.count == 1 ? "" : "s") running elsewhere (tmux) into tabs here")
            }
            Button {
                newTab(from: last, in: FileManager.default.homeDirectoryForCurrentUser.path, running: nil)
            } label: {
                Image(systemName: "house").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New tab in your home directory")
        }
    }

    private var strip: NSColor { NSColor(background).blended(withFraction: 0.07, of: .black) ?? NSColor(background) }

    /// Idle Claude sessions in terminals that aren't Ghostty's, such as the old tmux server's
    /// panes. Busy and waiting ones are left until they're idle, as stopping them would lose the
    /// turn or choice. A session also listed under its tab's terminal, or in the fork's own tmux
    /// (a closed window's, reattached at launch), is Ghostty's already.
    private var sessionsElsewhere: [ClaudeTab] {
        let here = OpenSessions.ttys.union(sessions.ghosttyPanes)
        let ours = Set(sessions.byTTY.filter { here.contains($0.key) }.map(\.value.session.pid))
        return Dictionary(
            sessions.byTTY.values
                .filter { !ours.contains($0.session.pid) && $0.session.status == .idle && $0.open != nil }
                .map { ($0.session.pid, $0) },
            uniquingKeysWith: { first, _ in first })
            .values
            .sorted { ($0.session.cwd ?? "") < ($1.session.cwd ?? "") }
    }

    /// Stops each session and resumes it in a new tab in its directory, under its account.
    private func bringHere(_ moving: [ClaudeTab], beside window: NSWindow) {
        for tab in moving {
            let pid = tab.session.pid
            kill(pid, SIGTERM)
            Task.detached {
                // Resuming while the old process still writes the transcript would fork it.
                for _ in 0..<40 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(250)) }
                guard kill(pid, 0) != 0 else { return }
                await MainActor.run { newTab(from: window, in: tab.session.cwd, running: tab.open?.resume) }
            }
        }
    }

    /// A tab after `window`'s, in `dir`, typing `input` into its shell.
    private func newTab(from window: NSWindow, in dir: String?, running input: String?) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = dir
        config.initialInput = input
        _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
    }
}

/// Takes a dragged tab or group's payload, outlining the view while one hovers over it.
private struct DropTarget: ViewModifier {
    let perform: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).opacity(targeted ? 1 : 0)
            }
            .onDrop(of: [.text], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let text = item as? NSString else { return }
                    let payload = text as String
                    DispatchQueue.main.async { perform(payload) }
                }
                return true
            }
    }
}

/// Dark text on light colors (Rec. 601 luma).
func readable(on color: NSColor) -> NSColor {
    guard let rgb = color.usingColorSpace(.sRGB) else { return .labelColor }
    let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    return luma > 0.59 ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1) : .white
}

private struct GroupLabel: View {
    let repo: String
    let color: NSColor

    var body: some View {
        Text(repo.isEmpty ? "other" : repo)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color(readable(on: color)))
            .background(Capsule().fill(Color(color)))
            .padding(.bottom, 4)
            .fixedSize()
    }
}

private struct TabView: View {
    let tab: StripTab
    let color: Color
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            StatusIcon(status: tab.status, onFill: tab.active)
            Text(tab.name)
                .font(.system(size: 12, weight: tab.active ? .semibold : .regular))
                .foregroundStyle(tab.active ? AnyShapeStyle(Color(readable(on: tab.color ?? .systemGray))) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .help([tab.name, tab.key, tab.account?.label].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "  ·  "))
        // Tabs share the strip evenly, as Safari's do, up to a cap.
        .frame(minWidth: 56, maxWidth: 220, minHeight: 26)
        // The selected tab is filled with its repo's color; the others sit back, dimmed, on a
        // thin underline.
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                .fill(tab.active ? color : Color.primary.opacity(hovered ? 0.06 : 0))
                .shadow(color: .black.opacity(tab.active ? 0.3 : 0), radius: 2, y: -0.5))
        // A tab running Claude is outlined in the color its session picked with /color.
        .overlay {
            if let outline = tab.outline {
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                    .strokeBorder(Color(outline), lineWidth: tab.active ? 2 : 1.5)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(color).frame(height: tab.active ? 3 : 1).opacity(tab.active ? 1 : 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onTapGesture { tab.window.tabGroup?.selectedWindow = tab.window }
    }
}

/// Claude's state in a tab: waiting on a choice, done and waiting on you, or working.
private struct StatusIcon: View {
    let status: ClaudeSession.Status?
    /// On the selected tab's fill, which can match the icon's color.
    let onFill: Bool

    var body: some View {
        switch status {
        case .waiting: icon("questionmark.circle.fill", .orange, "Waiting on your choice")
        case .idle: icon("checkmark.circle.fill", .green, "Done, your turn")
        case .busy: icon("arrow.triangle.2.circlepath", .blue, "Working")
        case .shell, nil: EmptyView()
        }
    }

    private func icon(_ name: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: name).font(.system(size: 11)).foregroundStyle(color)
            // On the fill, which can be its own color, it sits on a black disc.
            .background(Circle().fill(.black).frame(width: 15, height: 15).opacity(onFill ? 1 : 0))
            .help(help)
    }
}
