import AppKit

/// Keeps the Mac awake (display, idle and system sleep). With Amphetamine installed it drives
/// and mirrors Amphetamine's sessions, so both menu bars agree; otherwise it runs `caffeinate`,
/// which also ends when Ghostty quits.
@MainActor
final class Caffeine: ObservableObject {
    static let shared = Caffeine()

    /// When it lets the Mac sleep again: `.distantFuture` until turned off, nil when off.
    @Published private(set) var until: Date?
    private var process: Process?
    private var timer: Timer?

    private static let amphetamineID = "com.if.Amphetamine"
    private static let hasAmphetamine =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: amphetamineID) != nil

    private init() {
        guard Self.hasAmphetamine else { return }
        Task { await sync() }
        // Sessions started or ended from Amphetamine's own menu show up within a poll.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in await Caffeine.shared.sync() }
        }
    }

    /// Keeps the Mac awake for `seconds`, or until turned off when nil.
    func keepAwake(for seconds: Int?) {
        if Self.hasAmphetamine {
            // Amphetamine takes 0 duration with 0 interval as "until turned off".
            let options = seconds.map { "{duration:\(max(1, $0 / 60)), interval:minutes" } ?? "{duration:0, interval:0"
            until = seconds.map { Date().addingTimeInterval(TimeInterval($0)) } ?? .distantFuture
            Task {
                _ = await Self.amphetamine("start new session with options \(options), displaySleepAllowed:false}")
                await sync()
            }
            return
        }
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
        if Self.hasAmphetamine {
            until = nil
            Task { _ = await Self.amphetamine("end session") }
            return
        }
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

    /// Mirrors Amphetamine's session, without launching Amphetamine just to ask.
    private func sync() async {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.amphetamineID).isEmpty
        else { until = nil; return }
        // Seconds left, 0 for a session until turned off, -1 for none.
        let left = await Self.amphetamine(
            "if not (session is active) then return -1",
            "return session time remaining"
        ).flatMap(Double.init)
        switch left {
        case nil: return
        case let left? where left < 0: until = nil
        case 0?: until = .distantFuture
        case let left?:
            let next = Date().addingTimeInterval(left)
            // Ignore the second or so of drift between polls so the timer doesn't redraw.
            if abs((until ?? .distantPast).timeIntervalSince(next)) > 2 { until = next }
        }
    }

    /// Runs `lines` inside `tell application "Amphetamine"`; its trimmed output, nil on failure.
    private static func amphetamine(_ lines: String...) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let script = ["tell application id \"\(amphetamineID)\""] + lines + ["end tell"]
            process.arguments = script.flatMap { ["-e", $0] }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                continuation.resume(returning: process.terminationStatus == 0
                    ? output?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
