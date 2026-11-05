import Foundation

/// One line of claylib's stats log, written every 5 s by `claylib-sysstats --daemon`:
/// `time cpu% mem% battery% charging mem_mb swap_mb`, battery -1 on a Mac without one.
struct StatsSample: Equatable {
    let time: Int
    let cpu: Int
    let mem: Int
    let battery: Int?
    let charging: Bool
    let memMB: Int?
    let swapMB: Int?

    init?(line: Substring) {
        let fields = line.split(separator: " ").map { Int($0) }
        guard fields.count >= 5, let time = fields[0], let cpu = fields[1], let mem = fields[2],
              let battery = fields[3] else { return nil }
        self.time = time
        self.cpu = cpu
        self.mem = mem
        self.battery = battery < 0 ? nil : battery
        charging = fields[4] == 1
        memMB = fields.count > 5 ? fields[5] : nil
        swapMB = fields.count > 6 ? fields[6] : nil
    }
}

/// How alarming a value is: drawn plain, yellow or red.
enum StatLevel {
    case normal, warn, alert, good
}

/// The last hour of samples, summed up for the status bar.
struct Stats: Equatable {
    struct Battery: Equatable {
        let percent: Int
        let charging: Bool
        /// Change in %/h over 5m, 15m and 1h; nil with under a minute of samples in the span.
        let rates: [Int?]
    }

    static let spark = 20
    static let sparkWindow = 600
    static let rateSpans = [300, 900, 3600]
    static let averageSpans = [30, 600, 3600]

    let cpu: Int
    /// Average cpu in each of 20 slots over the last 10 minutes, oldest first; nil with no sample.
    let cpuSpark: [Int?]
    /// Average cpu over 30s, 10m and 1h.
    let cpuAverages: [Int?]
    let mem: Int
    let memUsedMB: Int?
    let swapMB: Int?
    let battery: Battery?

    /// Nil when the log has no sample in the last 30 s: the sampler isn't running.
    init?(samples: [StatsSample], now: Int) {
        let recent = samples.filter { $0.time > now - 3600 }
        guard let last = recent.last, last.time >= now - 30 else { return nil }
        cpu = last.cpu
        mem = last.mem
        memUsedMB = last.memMB
        swapMB = last.swapMB

        cpuAverages = Self.averageSpans.map { span in
            let values = recent.filter { now - $0.time < span }.map(\.cpu)
            return values.isEmpty ? nil : values.reduce(0, +) / values.count
        }
        var slots = [[Int]](repeating: [], count: Self.spark)
        for sample in recent where now - sample.time < Self.sparkWindow {
            slots[(Self.sparkWindow - 1 - (now - sample.time)) * Self.spark / Self.sparkWindow].append(sample.cpu)
        }
        cpuSpark = slots.map { $0.isEmpty ? nil : $0.reduce(0, +) / $0.count }

        let charged = recent.filter { $0.battery != nil }
        if let current = charged.last, let percent = current.battery {
            let rates: [Int?] = Self.rateSpans.map { span in
                // The log runs oldest first, so the first sample in the span is where it starts.
                guard let start = charged.first(where: { now - $0.time < span }),
                      let from = start.battery,
                      current.time - start.time >= 60 else { return nil }
                let rate = Double(percent - from) * 3600 / Double(current.time - start.time)
                return Int(rate.rounded(.toNearestOrAwayFromZero))
            }
            battery = Battery(percent: percent, charging: current.charging, rates: rates)
        } else {
            battery = nil
        }
    }

    static func parse(log: String, now: Int) -> Stats? {
        Stats(samples: log.split(separator: "\n").compactMap(StatsSample.init(line:)), now: now)
    }

    /// cpu: yellow from 60%, red from 85%.
    static func cpuLevel(_ value: Int) -> StatLevel { value >= 85 ? .alert : value >= 60 ? .warn : .normal }

    /// Memory: macOS idles near 75%, so yellow from 80%, red from 90%; the meter is green below.
    static func memLevel(_ value: Int) -> StatLevel { value >= 90 ? .alert : value >= 80 ? .warn : .good }

    /// Battery level: yellow at 30% or less, red at 15% or less; green while charging.
    static func batteryLevel(_ battery: Battery) -> StatLevel {
        battery.charging ? .good : battery.percent <= 15 ? .alert : battery.percent <= 30 ? .warn : .normal
    }

    /// Battery rate: green charging, yellow draining 10 %/h or faster, red 20 %/h or faster.
    static func rateLevel(_ rate: Int) -> StatLevel {
        rate > 0 ? .good : rate <= -20 ? .alert : rate <= -10 ? .warn : .normal
    }
}

/// The stats from claylib's log, reread whenever the sampler writes to it.
@MainActor
final class SystemStatsModel: ObservableObject {
    static let shared = SystemStatsModel()

    @Published private(set) var stats: Stats?

    private let log: String = {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.local/state"
        return state + "/claylib/statusline.log"
    }()
    private var watcher: FileWatcher?

    private init() {
        reload()
        // The sampler trims the log by replacing it, so the directory is what's watched.
        // shortcut: a sampler that stops leaves the last stats up, as nothing writes to say so.
        watcher = FileWatcher(paths: [(log as NSString).deletingLastPathComponent]) { [weak self] paths in
            guard let self, paths.contains(where: { $0.hasPrefix(self.log) }) else { return }
            reload()
        }
    }

    private func reload() {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let next = Stats.parse(log: text, now: Int(Date().timeIntervalSince1970))
        if next != stats { stats = next }
    }
}
