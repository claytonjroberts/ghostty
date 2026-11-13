import SwiftUI

/// The human tasks and questions Claude sessions left, in full, with Run, Done and answers; the
/// top of ClaylibMenuBar's popover.
struct HumanTasksView: View {
    @ObservedObject var model: HumanTasks
    @State private var showFinished = false

    var body: some View {
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
                if !task.done, task.saysIfBlocking {
                    Text(task.blocking ? "Blocking" : "Optional")
                        .fontWeight(.semibold)
                        .foregroundStyle(task.blocking ? .red : .secondary)
                }
                if !task.requester.isEmpty { Label(task.requester, systemImage: "person.crop.circle") }
                if let host = task.host, !host.isEmpty { Label(host, systemImage: "server.rack") }
                Text(Date(timeIntervalSince1970: task.created).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !task.details.isEmpty {
                Text(task.details)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !task.command.isEmpty {
                Text(task.command)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            }
            if let status = task.exitStatus { result(status) }
            if task.kind == .question { question }
            HStack {
                Spacer()
                if task.kind == .action, !task.command.isEmpty, !task.done {
                    Button(task.exitStatus == nil ? "Run" : "Run Again") { model.run(task) }.buttonStyle(.borderedProminent)
                }
                if task.done {
                    Button("Reopen") { model.reopen(task) }
                } else if task.kind == .action {
                    Button("Done") { model.done(task) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(task.blocking && !task.done ? Color.red.opacity(0.5) : Color.primary.opacity(0.1)))
        .opacity(task.done ? 0.6 : 1)
    }

    @ViewBuilder
    private func result(_ status: Int) -> some View {
        Label("Exited \(status)", systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(status == 0 ? .green : .red)
        if !task.output.isEmpty {
            Text(task.outputTail(lines: 12))
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
        }
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
