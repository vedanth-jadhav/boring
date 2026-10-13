import SwiftUI

struct FocusDurationPicker: View {
    @ObservedObject private var manager = FocusSessionManager.shared
    @ObservedObject private var selection = FocusSessionManager.shared.selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let editApps: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if selection.mode == .caffeine {
                CaffeineAppSummary(editing: true, action: editApps)
                Text("Keep working, even with the lid closed.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            DurationRuler(minutes: $selection.minutes)
            HStack(alignment: .firstTextBaseline) {
                Button(action: start) {
                    Label(manager.isBusy ? "Getting ready…" : selection.mode == .caffeine ? "Keep awake" : "Start Timer",
                          systemImage: selection.mode == .caffeine ? "cup.and.saucer.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 16).frame(height: 32).modifier(FocusControlSurface(accent: true))
                }
                .disabled(manager.isBusy)
                .keyboardShortcut(.return, modifiers: [])
                Spacer()
                Text(FocusSessionSnapshot.timeText(TimeInterval(selection.minutes * 60)))
                    .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                    .contentTransition(.numericText(value: Double(selection.minutes)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection.minutes)
                    .accessibilityLabel("\(selection.minutes) minutes")
            }
        }
        .frame(maxWidth: 500)
    }
    private func start() { manager.start() }
}
