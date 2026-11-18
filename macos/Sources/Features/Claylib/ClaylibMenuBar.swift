import AppKit
import Combine
import SwiftUI

/// Claylib: one menu bar item with the number of open terminal tabs. Its popover lists the tabs by
/// repo, each with its Claude status; choosing a tab brings it forward.
@MainActor
final class ClaylibMenuBar: NSObject, ObservableObject {
    static let shared = ClaylibMenuBar()

    /// What Restore would bring back, counted when the popover opens: it asks tmux.
    @Published private(set) var restorable = 0

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminals")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ClaylibMenuView(menu: self))
        // Tabs open and close with ClaylibTabs; Claude status changes with ClaudeSessions.
        ClaylibTabs.shared.$revision.sink { [weak self] _ in self?.updateTitle() }.store(in: &cancellables)
        ClaudeSessions.shared.$byTTY.sink { [weak self] _ in self?.updateTitle() }.store(in: &cancellables)    }

    /// Every terminal tab, window by window, in tab order.
    var tabs: [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return NSApp.windows.compactMap { $0 as? TerminalWindow }.flatMap { window -> [NSWindow] in
            let group = window.tabGroup?.windows ?? [window]
            guard seen.insert(ObjectIdentifier(group[0])).inserted else { return [] }
            return group
        }
    }

    private func updateTitle() {
        // After the change lands: ClaylibTabs publishes before the tab is gone, and @Published
        // sends before the property is set.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            item?.button?.title = " \(tabs.count)"
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        restorable = OpenSessions.shared.restorable        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func restore() {
        popover.performClose(nil)
        OpenSessions.shared.reopen()
        NSApp.activate(ignoringOtherApps: true)
    }

    func open(_ window: NSWindow) {
        popover.performClose(nil)
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ClaylibMenuView: View {
    @ObservedObject var menu: ClaylibMenuBar
    @ObservedObject private var tabRevisions = ClaylibTabs.shared
    @ObservedObject private var sessions = ClaudeSessions.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                terminals
            }
            .padding(14)
        }
        .frame(width: 460)
        .frame(minHeight: 120, maxHeight: 680)
    }

    @ViewBuilder
    private var terminals: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Terminals").font(.headline)
                Spacer()
                if menu.restorable > 0 {
                    Button("Restore \(menu.restorable) Session\(menu.restorable == 1 ? "" : "s")") { menu.restore() }
                }
            }
            let tabs = menu.tabs.map(StripTab.init(window:))
            if tabs.isEmpty { Text("No terminals").foregroundStyle(.secondary) }
            ForEach(Array(runs(tabs, by: \.repo).enumerated()), id: \.offset) { _, group in
                Text(group[0].repo.isEmpty ? "other" : group[0].repo)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(group, id: \.window) { tab in
                    Button { menu.open(tab.window) } label: {
                        HStack(spacing: 6) {
                            Text(tab.status?.mark ?? "").frame(width: 14)
                            Text(tab.name).lineLimit(1)
                            Spacer()
                            if tab.active && tab.window.isKeyWindow { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
