import Testing
@testable import Ghostty

struct StatsTests {
    private let now = 100_000

    /// One sample every `step` seconds over the last `span`, battery from `battery(age)`.
    private func log(span: Int, step: Int = 5, cpu: Int = 10, battery: (Int) -> Int) -> String {
        stride(from: span, through: 0, by: -step)
            .map { age in "\(now - age) \(cpu) 70 \(battery(age)) 0 16000 512" }
            .joined(separator: "\n")
    }

    @Test func parsesASample() {
        let sample = StatsSample(line: "100 21 69 -1 1 16896 921")
        #expect(sample?.battery == nil)
        #expect(sample?.charging == true)
        #expect(sample?.swapMB == 921)
        #expect(StatsSample(line: "garbage") == nil)
    }

    @Test func staleLogIsNoStats() {
        #expect(Stats.parse(log: "\(now - 31) 1 2 3 0", now: now) == nil)
        #expect(Stats.parse(log: "", now: now) == nil)
    }

    @Test func batteryRatePerSpan() throws {
        // Draining 1% a minute: -60%/h whatever the span.
        let stats = try #require(Stats.parse(log: log(span: 3000, step: 60) { 50 + $0 / 60 }, now: now))
        #expect(stats.battery?.rates == [-60, -60, -60])
        #expect(stats.battery?.percent == 50)
    }

    @Test func underAMinuteOfSamplesIsNoRate() throws {
        let stats = try #require(Stats.parse(log: log(span: 55) { _ in 80 }, now: now))
        #expect(stats.battery?.rates == [nil, nil, nil])
    }

    @Test func noBatteryIsNoBatteryRow() throws {
        let stats = try #require(Stats.parse(log: log(span: 600) { _ in -1 }, now: now))
        #expect(stats.battery == nil)
    }

    @Test func cpuAveragesAndSpark() throws {
        let text = log(span: 3000, cpu: 40) { _ in 90 } + "\n\(now) 100 70 90 0 16000 512"
        let stats = try #require(Stats.parse(log: text, now: now))
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
        #expect(Stats.rateLevel(3) == .good)
        #expect(Stats.rateLevel(-10) == .warn)
        #expect(Stats.rateLevel(-20) == .alert)
        #expect(Stats.batteryLevel(.init(percent: 15, charging: false, rates: [])) == .alert)
        #expect(Stats.batteryLevel(.init(percent: 15, charging: true, rates: [])) == .good)
    }
}
