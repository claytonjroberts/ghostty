import Foundation

/// Keeps the Mac awake (display, idle and system sleep) by running `caffeinate`, which also
/// ends when Ghostty quits.
@MainActor
final class Caffeine: ObservableObject {
    static let shared = Caffeine()

    /// When it lets the Mac sleep again: `.distantFuture` until turned off, nil when off.
    @Published private(set) var until: Date?
    private var process: Process?

    /// Keeps the Mac awake for `seconds`, or until turned off when nil.
    func keepAwake(for seconds: Int?) {
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dims", "-w", "\(getpid())"] + (seconds.map { ["-t", "\($0)"] } ?? [])
        let id = ObjectIdentifier(process)
        process.terminationHandler = { _ in
            Task { @MainActor in Caffeine.shared.ended(id) }
        }
        guard (try? process.run()) != nil else { return }
        self.process = process
        until = seconds.map { Date().addingTimeInterval(TimeInterval($0)) } ?? .distantFuture
    }

    func stop() {
        process?.terminate()
        process = nil
        until = nil
    }

    /// Its time ran out; a process already replaced or stopped changes nothing.
    private func ended(_ id: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == id else { return }
        self.process = nil
        until = nil
    }
}
