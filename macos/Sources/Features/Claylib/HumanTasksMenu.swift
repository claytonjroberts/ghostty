import AppKit
import Combine
import SwiftUI

/// Claylib: a menu bar flag with the number of human tasks waiting on Clayton; its popover lists
/// them in full, with Run and Done, and the questions sessions left for later.
@MainActor
final class HumanTasksMenu: NSObject {
    static let shared = HumanTasksMenu()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "flag", accessibilityDescription: "Human tasks")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: HumanTasksView(model: .shared))
        HumanTasks.shared.$tasks.sink { [weak self] _ in self?.updateTitle() }.store(in: &cancellables)
    }

    private func updateTitle() {
        // After the change lands: @Published sends before the property is set.
        DispatchQueue.main.async { [weak self] in
            let tasks = HumanTasks.shared
            let actions = tasks.openActions.count, questions = tasks.openQuestions.count
            self?.item?.button?.title = [actions > 0 ? " \(actions)" : "", questions > 0 ? " ?\(questions)" : ""].joined()
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        HumanTasks.shared.visit()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

struct HumanTasksView: View {
    @ObservedObject var model: HumanTasks
    @State private var showFinished = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.tasks.isEmpty {
                    Text("Nothing waiting on you.").foregroundStyle(.secondary)
                }
                section("To do", model.openActions)
                section("Questions, when you have a moment", model.openQuestions)
                if !model.finished.isEmpty {
                    DisclosureGroup("Done (\(model.finished.count))", isExpanded: $showFinished) {
                        VStack(spacing: 8) { ForEach(model.finished) { HumanTaskCard(task: $0, model: model) } }
                            .padding(.top, 6)
                    }
                    .font(.headline)
                }
            }
            .padding(14)
        }
        .frame(width: 460)
        .frame(minHeight: 120, maxHeight: 620)
    }

    @ViewBuilder
    private func section(_ title: String, _ tasks: [HumanTask]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(tasks) { HumanTaskCard(task: $0, model: model) }
            }
        }
    }
}

private struct HumanTaskCard: View {
    let task: HumanTask
    @ObservedObject var model: HumanTasks
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if let host = task.host, !host.isEmpty { Label(host, systemImage: "server.rack") }
                Text(Date(timeIntervalSince1970: task.created), style: .relative) + Text(" ago")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !task.command.isEmpty {
                Text(task.command)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
            if task.kind == .question { question }
            HStack {
                Spacer()
                if task.kind == .action, !task.command.isEmpty, !task.done {
                    Button("Run") { model.run(task) }.buttonStyle(.borderedProminent)
                }
                if task.done {
                    Button("Reopen") { model.reopen(task) }
                } else if task.kind == .action {
                    Button("Done") { model.done(task) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(task.done ? 0.6 : 1)
    }

    @ViewBuilder
    private var question: some View {
        if task.done {
            Text("Answered: \(task.answer)").fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(task.options, id: \.self) { option in
                Button(option) { model.answer(task, option) }
            }
            HStack {
                TextField("Your answer", text: $reply).onSubmit(send)
                Button("Answer", action: send).disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.answer(task, text)
    }
}
