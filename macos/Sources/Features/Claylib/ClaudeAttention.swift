import AppKit
import Combine

/// Claylib: Claude sessions that need you. The dock badge counts sessions waiting on a choice,
/// the dock bounces once when a session stops while Ghostty is in the background, and
/// Window > Next Claude Session Needing You (⌃⌘J) visits them in turn.
@MainActor
final class ClaudeAttention: NSObject {
    static let shared = ClaudeAttention()

    private var previous: [String: ClaudeSession.Status] = [:]
    private var cancellable: AnyCancellable?

    func install() {
        cancellable = ClaudeSessions.shared.$byTTY.sink { [weak self] in self?.update($0) }
        let item = NSMenuItem(title: "Next Claude Session Needing You", action: #selector(jumpToNext), keyEquivalent: "j")
        item.keyEquivalentModifierMask = [.control, .command]
        item.target = self
        NSApp.windowsMenu?.addItem(.separator())
        NSApp.windowsMenu?.addItem(item)
    }

    /// Done (idle) or stopped on a choice (waiting): either way it is your turn.
    nonisolated static func needsYou(_ status: ClaudeSession.Status) -> Bool { status == .idle || status == .waiting }

    /// Whether any session just turned to need you; one that newly appears doesn't count.
    nonisolated static func justStopped(from previous: [String: ClaudeSession.Status], to current: [String: ClaudeSession.Status]) -> Bool {
        current.contains { tty, status in
            guard let before = previous[tty] else { return false }
            return needsYou(status) && before != status && !(before == .waiting && status == .idle)
        }
    }

    private func update(_ tabs: [String: ClaudeTab]) {
        let current = tabs.mapValues(\.session.status)
        let waiting = current.values.filter { $0 == .waiting }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        if Self.justStopped(from: previous, to: current) && !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        previous = current
    }

    /// Focuses the next terminal, after the focused one in window and split order, whose Claude
    /// session needs you; sessions waiting on a choice come before ones that are done.
    @objc private func jumpToNext() {
        let tabs = ClaudeSessions.shared.byTTY
        let terminals = NSApp.orderedWindows
            .compactMap { $0.windowController as? BaseTerminalController }
            .flatMap { controller in controller.surfaceTree.map { (controller, $0) } }
        let focused = terminals.firstIndex { $0.1.window?.isKeyWindow == true && $0.0.focusedSurface === $0.1 } ?? -1
        let after = terminals.indices.map { (focused + 1 + $0) % max(terminals.count, 1) }
        for wanted in [ClaudeSession.Status.waiting, .idle] {
            if let next = after.first(where: { index in
                terminals[index].1.surfaceModel?.ttyName.flatMap { tabs[$0] }?.session.status == wanted
            }) {
                terminals[next].0.focusSurface(terminals[next].1)
                return
            }
        }
        NSSound.beep()
    }
}
