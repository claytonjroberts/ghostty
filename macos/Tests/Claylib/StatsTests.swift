import Foundation
import Testing
@testable import Ghostty

struct StatsTests {
    private let now = 100_000

    private func sample(age: Int, cpu: Int, battery: Int?) -> StatsSample {
        StatsSample(
            time: now - age, cpu: cpu, mem: 70, memMB: 16000, swapMB: 512, battery: battery, charging: false,
            down: 0, up: 0, disk: 50, diskFreeGB: 100)
    }

    /// One sample every `step` seconds over the last `span`, battery from `battery(age)`.
    private func samples(span: Int, step: Int = 2, cpu: Int = 10, battery: (Int) -> Int? = { _ in nil }) -> [StatsSample] {
        stride(from: span, through: 0, by: -step).map { sample(age: $0, cpu: cpu, battery: battery($0)) }
    }

    @Test func noSamplesIsNoStats() {
        #expect(Stats(samples: [], now: now) == nil)
    }

    @Test func batteryRatePerSpan() throws {
        // Draining 1% a minute: -60%/h whatever the span.
        let stats = try #require(Stats(samples: samples(span: 3000, step: 60) { 50 + $0 / 60 }, now: now))
        #expect(stats.battery?.rates == [-60, -60, -60])
        #expect(stats.battery?.percent == 50)
    }

    @Test func underAMinuteOfSamplesIsNoRate() throws {
        let stats = try #require(Stats(samples: samples(span: 55) { _ in 80 }, now: now))
        #expect(stats.battery?.rates == [nil, nil, nil])
    }

    @Test func noBatteryIsNoBattery() throws {
        #expect(try #require(Stats(samples: samples(span: 600), now: now)).battery == nil)
    }

    @Test func cpuAveragesAndSpark() throws {
        let all = samples(span: 3000, cpu: 40).dropLast() + [sample(age: 0, cpu: 100, battery: nil)]
        let stats = try #require(Stats(samples: Array(all), now: now))
        #expect(stats.cpu == 100)
        #expect(stats.cpuAverages[2] == 40)
        #expect(stats.cpuSpark.count == Stats.spark)
        // The newest sample lands in the last slot.
        #expect((stats.cpuSpark.last ?? 0) ?? 0 > 40)
    }

    @Test func levels() {
        #expect(Stats.cpuLevel(85) == .alert)
        #expect(Stats.memLevel(79) == .good)
        #expect(Stats.memLevel(80) == .warn)
        #expect(Stats.diskLevel(95) == .alert)
        #expect(Stats.rateLevel(3) == .good)
        #expect(Stats.rateLevel(-10) == .warn)
        #expect(Stats.rateLevel(-20) == .alert)
        #expect(Stats.batteryLevel(.init(percent: 15, charging: false, rates: [])) == .alert)
        #expect(Stats.batteryLevel(.init(percent: 15, charging: true, rates: [])) == .good)
    }

    @Test func rates() {
        #expect(Stats.rate(812) == "812 B/s")
        #expect(Stats.rate(12_400) == "12 KB/s")
        #expect(Stats.rate(1_440_000) == "1.4 MB/s")
    }

    @Test @MainActor func samplesThisMac() throws {
        let stats = try #require(SystemStatsModel.shared.stats)
        #expect((0...100).contains(stats.cpu))
        #expect(stats.mem > 0 && stats.memUsedMB > 0)
        #expect(stats.disk > 0)
    }
}

struct PullRequestTests {
    /// The shape `pr_status.py --json` prints.
    @Test func decodesPrStatusJson() throws {
        let json = #"[{"url": "https://github.com/o/r/pull/7", "title": "Fix", "status": "CI failing", "icon": "🔴", "number": 7, "head": "fix"}]"#
        let prs = try JSONDecoder().decode([PullRequest].self, from: Data(json.utf8))
        #expect(prs == [PullRequest(number: 7, title: "Fix", url: "https://github.com/o/r/pull/7", status: "CI failing", icon: "🔴", head: "fix")])
    }
}
