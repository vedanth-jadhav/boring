import SwiftUI

struct CodexQuotaLane: View {
    let window: CodexQuotaSnapshot.Window
    let now: Date
    let recorded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overdue: Bool { window.needsRefresh(at: now) }
    private var tint: Color { overdue ? .white.opacity(0.45) : .white }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(window.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(resetLabel)
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(width: 132, alignment: .leading)
            CodexAllowanceTrack(fraction: 1).fill(.white.opacity(0.09))
                .overlay {
                    CodexAllowanceTrack(fraction: overdue ? 0 : window.remaining / 100).fill(tint)
                }
                .frame(height: 6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: window.remaining)
            VStack(alignment: .trailing, spacing: 2) {
                Text(overdue ? "—" : "\(Int(window.remaining.rounded()))%")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(tint)
                    .contentTransition(.numericText())
                Text("left").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: 56, alignment: .trailing)
        }
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title), \(overdue ? "reset awaiting refresh" : "\(Int(window.remaining)) percent remaining"), \(resetLabel)\(recorded ? ", recorded in local logs" : "")")
        .help(window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Reset time unavailable")
    }

    private var resetLabel: String {
        guard let date = window.resetsAt else { return "Reset time unavailable" }
        if date <= now { return "Reset due · awaiting fresh reading" }
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes >= 1_440 { return "Resets in \(minutes / 1_440)d \((minutes % 1_440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}
