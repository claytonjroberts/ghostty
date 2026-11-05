import SwiftUI

/// Claylib's bar under each window's terminals: the focused terminal's Claude account on the
/// left, the machine's stats on the right, each in an outline.
struct ClaylibStatusBar: View {
    /// The focused terminal's tty and directory, for the Claude account it bills to.
    let tty: String?
    let dir: String?
    /// The terminal's background, behind the outline titles.
    let background: Color

    @ObservedObject private var sessions = ClaudeSessions.shared
    @ObservedObject private var model = SystemStatsModel.shared

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let account = sessions.account(tty: tty, dir: dir) {
                Outlined(title: nil, background: background) {
                    Text(account.label).bold().foregroundColor(account.color.map(Color.init))
                }
            }
            Spacer(minLength: 0)
            Outlined(title: "stats", background: background) {
                if let stats = model.stats {
                    StatsRows(stats: stats)
                } else {
                    Text("sysstats sampler not running").foregroundColor(.secondary)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// A rounded outline with an optional title cut into its top edge.
private struct Outlined<Content: View>: View {
    let title: String?
    let background: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.5)))
            .overlay(alignment: .topLeading) {
                if let title {
                    Text(title)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 3)
                        .background(background)
                        .offset(x: 8, y: -7)
                }
            }
    }
}

private struct StatsRows: View {
    let stats: Stats

    private static let bars = Array("▁▂▃▄▅▆▇█").map(String.init)

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
            GridRow {
                Text("cpu")
                paint(percent(stats.cpu), Stats.cpuLevel(stats.cpu))
                Text("")
                stats.cpuSpark.reduce(Text("")) { line, slot in
                    line + (slot.map { paint(Self.bars[$0 * 8 / 101], Stats.cpuLevel($0)) } ?? Text(" "))
                }
                spans(["30s", "10m", "1h"], stats.cpuAverages.map { average in
                    average.map { paint(percent($0), Stats.cpuLevel($0)) } ?? Text("   -")
                })
            }
            GridRow {
                let level = Stats.memLevel(stats.mem)
                let full = (stats.mem * Stats.spark + 50) / 100
                Text("mem")
                paint(percent(stats.mem), level == .good ? .normal : level)
                Text(stats.memUsedMB.map { String(format: "%.1f/%dG", Double($0) / 1024, Self.totalGB) } ?? "")
                paint(String(repeating: "█", count: full), level)
                    + Text(String(repeating: "░", count: Stats.spark - full)).foregroundColor(.secondary)
                Text("swap " + (stats.swapMB.map { String(format: "%.1fG", Double($0) / 1024) } ?? "-"))
            }
            if let battery = stats.battery {
                GridRow {
                    Text("batt")
                    paint(percent(battery.percent), Stats.batteryLevel(battery))
                    Text("")
                    Text("")
                    spans(["5m", "15m", "1h"], battery.rates.map { rate in
                        let shown = rate.map { ($0 > 0 ? "+" : "") + "\($0)%/h" } ?? "-"
                        let padded = String(repeating: " ", count: max(0, 7 - shown.count)) + shown
                        return rate.map { paint(padded, Stats.rateLevel($0)) } ?? Text(padded)
                    })
                }
            }
        }
    }

    private static let totalGB = Int(ProcessInfo.processInfo.physicalMemory >> 30)

    private func percent(_ value: Int) -> String { String(format: "%3d%%", value) }

    private func spans(_ names: [String], _ values: [Text]) -> Text {
        zip(names, values).enumerated().reduce(Text("")) { line, item in
            line + Text((item.offset == 0 ? "" : "  ") + item.element.0 + " ") + item.element.1
        }
    }

    private func paint(_ text: String, _ level: StatLevel) -> Text {
        switch level {
        case .normal: Text(text)
        case .good: Text(text).foregroundColor(.green)
        case .warn: Text(text).foregroundColor(.orange)
        case .alert: Text(text).foregroundColor(.red)
        }
    }
}
