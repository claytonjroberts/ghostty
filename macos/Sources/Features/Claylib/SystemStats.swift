import Foundation
import IOKit.ps

/// One reading of the machine, taken every 2 s by SystemStatsModel.
struct StatsSample: Equatable {
    let time: Int
    let cpu: Int
    /// Activity Monitor's "Memory Used": app (anonymous - purgeable) + wired + compressed.
    let mem: Int
    let memMB: Int
    let swapMB: Int
    let battery: Int?
    /// On AC power, whether or not the battery is filling.
    let charging: Bool
    /// Bytes per second over Wi-Fi and Ethernet since the previous reading.
    let down: Int
    let up: Int
    let disk: Int
    let diskFreeGB: Int
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
        /// Change in %/h over the last 15 minutes; nil with under a minute of samples.
        let rate: Int?

        /// Time left until 5% at the current drain, as "1h35m" or "40m"; nil unless draining.
        var untilEmpty: String? {
            guard let rate, rate < 0 else { return nil }
            let minutes = max(percent - 5, 0) * 60 / -rate
            return minutes >= 60 ? "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
        }
    }

    static let spark = 30
    static let sparkWindow = 120
    static let rateSpan = 900
    static let averageSpans = [30, 600, 3600]

    let cpu: Int
    /// Average cpu in each of 30 slots over the last 2 minutes, oldest first; nil with no sample.
    let cpuSpark: [Int?]
    /// Average cpu over 30s, 10m and 1h.
    let cpuAverages: [Int?]
    let mem: Int
    let memUsedMB: Int
    let swapMB: Int
    let down: Int
    let up: Int
    let disk: Int
    let diskFreeGB: Int
    let battery: Battery?

    /// Nil with no samples yet.
    init?(samples: [StatsSample], now: Int) {
        let recent = samples.filter { $0.time > now - 3600 }
        guard let last = recent.last else { return nil }
        cpu = last.cpu
        mem = last.mem
        memUsedMB = last.memMB
        swapMB = last.swapMB
        down = last.down
        up = last.up
        disk = last.disk
        diskFreeGB = last.diskFreeGB

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
            // Samples run oldest first, so the first one in the span is where it starts.
            let start = charged.first { now - $0.time < Self.rateSpan }
            let rate: Int? = start.flatMap { start in
                guard let from = start.battery, current.time - start.time >= 60 else { return nil }
                let rate = Double(percent - from) * 3600 / Double(current.time - start.time)
                return Int(rate.rounded(.toNearestOrAwayFromZero))
            }
            battery = Battery(percent: percent, charging: current.charging, rate: rate)
        } else {
            battery = nil
        }
    }

    /// cpu: yellow from 60%, red from 85%.
    static func cpuLevel(_ value: Int) -> StatLevel { value >= 85 ? .alert : value >= 60 ? .warn : .normal }

    /// Memory: macOS idles near 75%, so yellow from 80%, red from 90%; the meter is green below.
    static func memLevel(_ value: Int) -> StatLevel { value >= 90 ? .alert : value >= 80 ? .warn : .normal }

    /// Disk: yellow from 85% full, red from 95%.
    static func diskLevel(_ value: Int) -> StatLevel { value >= 95 ? .alert : value >= 85 ? .warn : .good }

    /// Battery level: yellow at 30% or less, red at 15% or less; green while charging.
    static func batteryLevel(_ battery: Battery) -> StatLevel {
        battery.charging ? .good : battery.percent <= 15 ? .alert : battery.percent <= 30 ? .warn : .normal
    }

    /// The fastest a battery can drain, in %/h: a 14" M4 Pro MacBook Pro's 72 Wh at its ~80 W peak.
    static let fastestDrain = 110

    /// Battery rate: green charging, yellow draining 10 %/h or faster, red 20 %/h or faster.
    static func rateLevel(_ rate: Int) -> StatLevel {
        rate > 0 ? .good : rate <= -20 ? .alert : rate <= -10 ? .warn : .normal
    }

    /// "812 B/s", "12 KB/s", "1.4 MB/s".
    static func rate(_ bytes: Int) -> String {
        switch bytes {
        case ..<1000: "\(bytes) B/s"
        case ..<1_000_000: "\(bytes / 1000) KB/s"
        default: String(format: "%.1f MB/s", Double(bytes) / 1_000_000)
        }
    }
}

/// The machine's stats, sampled every 2 s while Ghostty runs; an hour of samples kept.
@MainActor
final class SystemStatsModel: ObservableObject {
    static let shared = SystemStatsModel()

    @Published private(set) var stats: Stats?

    private var samples: [StatsSample] = []
    private var meter = Meter()
    private var timer: Timer?

    private init() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SystemStatsModel.shared.tick() }
        }
    }

    private func tick() {
        let now = Int(Date().timeIntervalSince1970)
        samples.append(meter.read(now: now))
        samples.removeAll { $0.time <= now - 3600 }
        let next = Stats(samples: samples, now: now)
        if next != stats { stats = next }
    }
}

/// Reads the counters a sample is built from; cpu and network are deltas from the last read.
private struct Meter {
    private var ticks: (busy: UInt64, total: UInt64) = (0, 0)
    private var bytes: [String: (down: UInt32, up: UInt32)] = [:]
    private var time = 0

    mutating func read(now: Int) -> StatsSample {
        let cpuNow = Self.cpuTicks()
        let cpu = cpuNow.total > ticks.total
            ? Int((cpuNow.busy - ticks.busy) * 100 / (cpuNow.total - ticks.total)) : 0
        ticks = cpuNow

        // Interface counters are 32 bits, so each one's change is taken with wrapping.
        let bytesNow = Self.interfaceBytes()
        let elapsed = max(now - time, 1)
        var down = 0, up = 0
        for (name, current) in bytesNow {
            guard let before = bytes[name] else { continue }
            down += Int(current.down &- before.down)
            up += Int(current.up &- before.up)
        }
        let first = time == 0
        bytes = bytesNow
        time = now

        let (mem, memMB) = Self.memory()
        let (battery, charging) = Self.battery()
        let (disk, diskFreeGB) = Self.disk()
        return StatsSample(
            time: now, cpu: cpu, mem: mem, memMB: memMB, swapMB: Self.swapMB(),
            battery: battery, charging: charging,
            down: first ? 0 : down / elapsed, up: first ? 0 : up / elapsed,
            disk: disk, diskFreeGB: diskFreeGB)
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    private static func memory() -> (percent: Int, usedMB: Int) {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let pages = UInt64(info.internal_page_count) - UInt64(info.purgeable_count)
            + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let used = pages * UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        return (Int(used * 100 / total), Int(used >> 20))
    }

    private static func swapMB() -> Int {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int(usage.xsu_used >> 20)
    }

    private static func battery() -> (percent: Int?, charging: Bool) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (current * 100 / max, description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return (nil, false)
    }

    /// Received and sent bytes of each Wi-Fi or Ethernet interface ("en…"), so VPN tunnels
    /// don't count traffic twice.
    private static func interfaceBytes() -> [String: (down: UInt32, up: UInt32)] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [:] }
        defer { freeifaddrs(first) }
        var result: [String: (down: UInt32, up: UInt32)] = [:]
        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            let name = String(cString: entry.ifa_name)
            if name.hasPrefix("en") { result[name] = (data.ifi_ibytes, data.ifi_obytes) }
        }
        return result
    }

    private static func disk() -> (percent: Int, freeGB: Int) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage else { return (0, 0) }
        return (Int((Int64(total) - free) * 100 / Int64(total)), Int(free / 1_000_000_000))
    }
}
