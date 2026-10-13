import SwiftUI

struct FocusActiveSessionView: View {
    @ObservedObject private var manager = FocusSessionManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let editApps: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 1, paused: manager.session.state == .paused)) { context in
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(manager.isBusy ? "Restoring your Mac…" : manager.session.state == .paused ? "Paused" : manager.session.mode == .caffeine ? "Your apps can keep working" : "Timer",
                              systemImage: manager.session.mode.symbol)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                        Text(FocusSessionSnapshot.timeText(manager.session.remaining(at: context.date)))
                            .font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: Int(ceil(manager.session.remaining(at: context.date))))
                    }
                    Spacer(minLength: 12)
                    Button(action: togglePause) {
                        Label(manager.session.state == .paused ? "Resume" : "Pause", systemImage: manager.session.state == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: 32)
                            .modifier(FocusControlSurface(accent: true))
                    }.disabled(manager.isBusy)
                    Button("End session", systemImage: "xmark", action: manager.cancel)
                        .labelStyle(.iconOnly).font(.system(size: 11, weight: .semibold)).frame(width: 32, height: 32)
                        .modifier(FocusControlSurface()).disabled(manager.isBusy).help("End session and restore your Mac")
                }
            }
            .frame(height: 82)
            if manager.session.mode == .caffeine {
                CaffeineAppSummary(editing: false, action: editApps)
            }
        }.frame(maxWidth: 500)
    }
    private func togglePause() {
        if manager.session.state == .paused { manager.resume() } else { manager.pause() }
    }
}
