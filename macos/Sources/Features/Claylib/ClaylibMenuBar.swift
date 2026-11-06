import AppKit
import Combine

/// Claylib: a menu bar item with the number of open terminal tabs; its menu lists them by repo,
/// each with its Claude status, and choosing one brings that tab forward.
@MainActor
final class ClaylibMenuBar: NSObject, NSMenuDelegate {
    static let shared = ClaylibMenuBar()

    private var item: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminals")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        // Tabs open and close with ClaylibTabs; Claude status changes with ClaudeSessions.
        ClaylibTabs.shared.$revision.sink { [weak self] _ in self?.updateTitle() }.store(in: &cancellables)
        ClaudeSessions.shared.$byTTY.sink { [weak self] _ in self?.updateTitle() }.store(in: &cancellables)
    }

    /// Every terminal tab, window by window, in tab order.
    private var tabs: [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return NSApp.windows.compactMap { $0 as? TerminalWindow }.flatMap { window -> [NSWindow] in
            let group = window.tabGroup?.windows ?? [window]
            guard seen.insert(ObjectIdentifier(group[0])).inserted else { return [] }
            return group
        }
    }

    private func updateTitle() {
        // After the change lands: ClaylibTabs publishes before the tab is gone.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            item?.button?.title = " \(tabs.count)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for group in runs(tabs.map(StripTab.init(window:)), by: \.repo) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem(title: group[0].repo.isEmpty ? "other" : group[0].repo, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for tab in group {
                let mark = tab.status.map(\.mark).flatMap { $0.isEmpty ? nil : $0 + " " } ?? ""
                let entry = NSMenuItem(title: mark + tab.name, action: #selector(open(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = tab.window
                entry.state = tab.active && tab.window.isKeyWindow ? .on : .off
                entry.indentationLevel = 1
                menu.addItem(entry)
            }
        }
        if menu.numberOfItems == 0 {
            menu.addItem(NSMenuItem(title: "No terminals", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
