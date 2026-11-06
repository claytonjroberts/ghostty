import SwiftUI

/// Claylib's bar under each window's terminals: the focused terminal's Claude account and the
/// PR of its branch on the left; the machine's stats, drawn like the Stats app's menu bar
/// widgets, and the keep-awake cup on the right.
struct ClaylibStatusBar: View {
    /// The focused terminal's tty and directory, for its Claude account and PR.
    let tty: String?
    let dir: String?

    @ObservedObject private var sessions = ClaudeSessions.shared
    @ObservedObject private var model = SystemStatsModel.shared
    @ObservedObject private var prs = PullRequests.shared
    @State private var repo: TabRepo?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let account = sessions.account(tty: tty, dir: dir) {
                Outlined {
                    Text(account.label).bold().foregroundColor(account.color.map(Color.init))
                }
            }
            if let pr = repo.flatMap(prs.pr(for:)) {
                PRBox(pr: pr)
            }
            Spacer(minLength: 0)
            if let stats = model.stats {
                StatsWidgets(stats: stats).fixedSize()
            }
            CaffeineButton()
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .task(id: dir) {
            guard let dir else { repo = nil; return }
            let found = await TabRepo.lookup(dir)
            repo = found
            while !Task.isCancelled {
                await prs.refresh(found, dir: dir)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }
}

/// A rounded outline.
private struct Outlined<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.5)))
    }
}

/// The focused branch's PR: its status, number and title; a click opens it.
private struct PRBox: View {
    let pr: PullRequest

    var body: some View {
        Outlined {
            HStack(spacing: 6) {
                Text(pr.icon)
                // verbatim: an interpolated Int is localized to "#31,291".
                Text(verbatim: "#\(pr.number)").bold()
                Text(pr.title).lineLimit(1).truncationMode(.tail)
                Text(pr.status).foregroundColor(.secondary).lineLimit(1).fixedSize()
            }
            .font(.system(size: 11))
        }
        .contentShape(Rectangle())
        .onTapGesture { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } }
        .help("\(pr.url)\nfrom \(pr.head)")
    }
}

/// CPU, memory, disk, network and battery, each a small label over its value beside a chart or
/// meter, as the Stats app draws its menu bar widgets. Details are in each one's tooltip.
private struct StatsWidgets: View {
    let stats: Stats

    private static let totalGB = Int(ProcessInfo.processInfo.physicalMemory >> 30)

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Labeled("CPU", "\(stats.cpu)%", Stats.cpuLevel(stats.cpu))
                Spark(values: stats.cpuSpark, color: color(Stats.cpuLevel(stats.cpu)) ?? .accentColor)
                    .frame(width: 40, height: 18)
            }
            .help(zip(["30s", "10m", "1h"], stats.cpuAverages)
                .map { "\($0) \($1.map { "\($0)%" } ?? "-")" }
                .joined(separator: "  ·  "))

            HStack(spacing: 4) {
                Labeled("RAM", String(format: "%.1fG", Double(stats.memUsedMB) / 1024), Stats.memLevel(stats.mem))
                Meter(percent: stats.mem, color: color(Stats.memLevel(stats.mem)) ?? .green)
            }
            .help(String(format: "%d%% of %d GB used  ·  swap %.1f GB", stats.mem, Self.totalGB, Double(stats.swapMB) / 1024))

            HStack(spacing: 4) {
                Labeled("SSD", "\(stats.disk)%", Stats.diskLevel(stats.disk))
                Meter(percent: stats.disk, color: color(Stats.diskLevel(stats.disk)) ?? .green)
            }
            .help("\(stats.diskFreeGB) GB free")

            VStack(alignment: .trailing, spacing: -1) {
                Text("↑ " + Stats.rate(stats.up))
                Text("↓ " + Stats.rate(stats.down))
            }
            .font(.system(size: 9, design: .monospaced))
            .frame(width: 70, alignment: .trailing)

            if let battery = stats.battery {
                HStack(spacing: 6) {
                    Labeled("BAT", "\(battery.percent)%", Stats.batteryLevel(battery))
                    Labeled("%/H", battery.rate.map { ($0 > 0 ? "+" : "") + "\($0)" } ?? "-",
                            battery.rate.map(Stats.rateLevel) ?? .normal)
                }
                .help("Battery, and its change per hour over the last 15 minutes")
            }
        }
    }
}

/// Plain is nil: the caller's default.
private func color(_ level: StatLevel) -> Color? {
    switch level {
    case .normal: nil
    case .good: .green
    case .warn: .orange
    case .alert: .red
    }
}

/// A small caps label over its value, as the Stats app stacks them.
private struct Labeled: View {
    let label: String
    let value: String
    let level: StatLevel

    init(_ label: String, _ value: String, _ level: StatLevel) {
        self.label = label
        self.value = value
        self.level = level
    }

    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(label).font(.system(size: 7, weight: .semibold)).foregroundColor(.secondary)
            // A green "good" is for meters; the number stays plain.
            Text(value).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(level == .good ? nil : color(level))
        }
        .frame(minWidth: 30, alignment: .leading)
    }
}

/// A filled line chart of percentages, oldest first, skipping slots with no sample.
private struct Spark: View {
    let values: [Int?]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let step = geometry.size.width / CGFloat(max(values.count - 1, 1))
            let height = geometry.size.height
            let points = values.enumerated().compactMap { index, value in
                value.map { CGPoint(x: CGFloat(index) * step, y: height - CGFloat(min($0, 100)) / 100 * height) }
            }
            ZStack {
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: height))
                }
                .fill(color.opacity(0.3))
                Path { path in path.addLines(points) }
                    .stroke(color, lineWidth: 1)
            }
        }
        .padding(1)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
    }
}

/// A vertical bar filled to a percentage.
private struct Meter: View {
    let percent: Int
    let color: Color

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.25))
            RoundedRectangle(cornerRadius: 1.5).fill(color)
                .frame(height: 18 * CGFloat(min(percent, 100)) / 100)
        }
        .frame(width: 5, height: 18)
    }
}

/// The keep-awake cup: filled while the Mac is kept awake, with the time left beside it.
private struct CaffeineButton: View {
    @ObservedObject private var caffeine = Caffeine.shared

    var body: some View {
        HStack(spacing: 3) {
            Menu {
                Button("Keep Awake for 1 Hour") { caffeine.keepAwake(for: 3600) }
                Button("Keep Awake for 3 Hours") { caffeine.keepAwake(for: 3 * 3600) }
                Button("Keep Awake for 8 Hours") { caffeine.keepAwake(for: 8 * 3600) }
                Button("Keep Awake Until Turned Off") { caffeine.keepAwake(for: nil) }
                Divider()
                Button("Allow Sleep") { caffeine.stop() }.disabled(caffeine.until == nil)
            } label: {
                Image(systemName: caffeine.until == nil ? "cup.and.saucer" : "cup.and.saucer.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundColor(caffeine.until == nil ? .secondary : .orange)
            if let until = caffeine.until, until != .distantFuture {
                Text(until, style: .timer).font(.system(size: 10).monospacedDigit()).foregroundColor(.orange)
            }
        }
        .help(caffeine.until == nil ? "Keep the Mac awake" : "Keeping the Mac awake")
    }
}
