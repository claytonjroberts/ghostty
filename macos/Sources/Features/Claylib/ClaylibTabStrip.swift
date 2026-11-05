import SwiftUI

/// Bumped whenever anything a tab strip draws changes (a tab's title, repo, Claude session,
/// key or selection), so every window's strip redraws from its tab group.
@MainActor
final class ClaylibTabs: ObservableObject {
    static let shared = ClaylibTabs()
    @Published private(set) var revision = 0
    func changed() { revision &+= 1 }
}

/// One tab as the strip draws it.
struct StripTab: Equatable {
    let window: NSWindow
    /// "" outside a repo, drawn as "other".
    let repo: String
    let color: NSColor?
    let account: NSColor?
    /// The window title: the Claude mark and session name, else the branch, else the shell's title.
    let title: String
    let key: String
    let active: Bool

    @MainActor
    init(window: NSWindow) {
        let terminal = window as? TerminalWindow
        self.window = window
        repo = terminal?.tabRepo?.name ?? ""
        color = terminal?.tabRepo?.color
        let surface = (window.windowController as? BaseTerminalController)?.focusedSurface
        account = ClaudeSessions.shared.account(tty: surface?.surfaceModel?.ttyName, dir: surface?.pwd)?.color
        title = window.title
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

/// Claylib: the window's tabs grouped under their repo's label, in place of the native tab bar
/// (hidden by TerminalWindow). A tab is a pill in its repo's color, full for the selected one
/// and blended into the strip for the rest, with a block in its Claude account's color. The +
/// after a group opens a tab beside it, in its directory, running Claude.
struct ClaylibTabStrip: View {
    /// Any terminal in the window; its window is read on every redraw, as tabs move between windows.
    let surface: Ghostty.SurfaceView?
    let background: Color

    @ObservedObject private var tabs = ClaylibTabs.shared
    @ObservedObject private var sessions = ClaudeSessions.shared

    var body: some View {
        let windows = surface?.window.map { $0.tabGroup?.windows ?? [$0] } ?? []
        let groups = runs(windows.map(StripTab.init(window:)), by: \.repo)
        FlowLayout(spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                // The label stays on its first tab's row and the + on its last tab's.
                ForEach(Array(group.enumerated()), id: \.offset) { index, tab in
                    HStack(spacing: 8) {
                        if index == 0 { Flag(repo: tab.repo, color: shade(tab.color)) }
                        Pill(tab: tab, color: shade(tab.color), strip: strip)
                        if index == group.count - 1 {
                            Button { newTab(beside: tab.window) } label: {
                                Text("+").bold().foregroundStyle(Color(shade(tab.color)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(strip))
        .id(tabs.revision)
    }

    private var strip: NSColor { NSColor(background).blended(withFraction: 0.06, of: .black) ?? NSColor(background) }

    private func shade(_ color: NSColor?) -> NSColor { color ?? .systemGray }

    private func newTab(beside window: NSWindow) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = (window.windowController as? BaseTerminalController)?.focusedSurface?.pwd
        config.initialInput = "claude\n"
        _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
    }
}

/// Dark text on light colors (Rec. 601 luma).
func readable(on color: NSColor) -> NSColor {
    guard let rgb = color.usingColorSpace(.sRGB) else { return .labelColor }
    let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    return luma > 0.59 ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.95, blue: 0.78, alpha: 1)
}

/// A repo's label: square and bold, so it never reads as a tab.
private struct Flag: View {
    let repo: String
    let color: NSColor

    var body: some View {
        Text(repo.isEmpty ? "other" : String(repo.prefix(12)))
            .bold()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color(readable(on: color)))
            .background(Color(color))
    }
}

private struct Pill: View {
    let tab: StripTab
    let color: NSColor
    let strip: NSColor
    @State private var hovered = false

    var body: some View {
        let fill = tab.active ? color : color.blended(withFraction: hovered ? 0.25 : 0.5, of: strip) ?? color
        HStack(spacing: 4) {
            if let account = tab.account {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(account)).frame(width: 6, height: 12)
            }
            Text("\(tab.key.isEmpty ? "" : tab.key + " ")\(String(tab.title.prefix(28)))")
                .bold(tab.active)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .foregroundStyle(Color(readable(on: fill)))
        .background(Capsule().fill(Color(fill)))
        .contentShape(Capsule())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .onTapGesture { tab.window.tabGroup?.selectedWindow = tab.window }
    }
}

/// Lays its views out left to right, wrapping onto a new row when one is full.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.maxX).max() ?? 0, height: rows.last.map { $0.minY + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(arrange(width: bounds.width, subviews: subviews).flatMap(\.frames), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private struct Row { var frames: [CGRect] = []; var minY: CGFloat; var height: CGFloat = 0; var maxX: CGFloat { frames.last?.maxX ?? 0 } }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row(minY: 0)]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].frames.isEmpty && rows[rows.count - 1].maxX + spacing + size.width > width {
                rows.append(Row(minY: rows[rows.count - 1].minY + rows[rows.count - 1].height + 4))
            }
            let x = rows[rows.count - 1].frames.isEmpty ? 0 : rows[rows.count - 1].maxX + spacing
            rows[rows.count - 1].frames.append(CGRect(origin: CGPoint(x: x, y: rows[rows.count - 1].minY), size: size))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
