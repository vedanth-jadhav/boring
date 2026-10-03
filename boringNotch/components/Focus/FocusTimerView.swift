import SwiftUI

struct FocusTimerView: View {
    @ObservedObject private var manager = FocusSessionManager.shared
    @ObservedObject private var selection = FocusSessionManager.shared.selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var modeNamespace

    var body: some View {
        VStack(spacing: 10) {
            if manager.isActive {
                TimelineView(.animation(minimumInterval: 1, paused: manager.session.state == .paused)) { context in
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(manager.session.state == .paused ? "Paused" : manager.session.mode == .caffeine ? "Keeping Mac awake" : "Timer",
                                  systemImage: manager.session.mode.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                            Text(FocusSessionSnapshot.timeText(manager.session.remaining(at: context.date)))
                                .font(.system(size: 38, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText(countsDown: true))
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: Int(ceil(manager.session.remaining(at: context.date))))
                        }
                        Spacer(minLength: 12)
                        Button(action: togglePause) {
                            Label(manager.session.state == .paused ? "Resume" : "Pause", systemImage: manager.session.state == .paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 14).frame(height: 32)
                                .modifier(FocusControlSurface(accent: true))
                        }
                        Button(action: manager.cancel) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .modifier(FocusControlSurface())
                        }
                        .accessibilityLabel("Cancel \(manager.session.mode.title)")
                        .help("Cancel session")
                    }
                }
                .frame(height: 100)
            } else {
                HStack(spacing: 2) {
                    ForEach(FocusSessionMode.allCases) { mode in
                        Button { selectMode(mode) } label: {
                            Text(mode.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selection.mode == mode ? .orange : .white.opacity(0.65))
                                .padding(.horizontal, 14).frame(height: 25)
                                .background {
                                    if selection.mode == mode {
                                        Capsule().fill(.orange.opacity(0.15))
                                            .matchedGeometryEffect(id: "mode", in: modeNamespace)
                                    }
                                }
                        }
                        .accessibilityAddTraits(selection.mode == mode ? .isSelected : [])
                    }
                }
                .padding(3)
                .modifier(FocusControlSurface())

                DurationRuler(minutes: $selection.minutes)
                    .frame(maxWidth: 500)

                HStack(alignment: .firstTextBaseline) {
                    Button(action: start) {
                        Label(selection.mode == .caffeine ? "Keep awake" : "Start Timer", systemImage: selection.mode == .caffeine ? "cup.and.saucer.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 16).frame(height: 32)
                            .modifier(FocusControlSurface(accent: true))
                    }
                    Spacer()
                    Text(FocusSessionSnapshot.timeText(TimeInterval(selection.minutes * 60)))
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText(value: Double(selection.minutes)))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection.minutes)
                        .accessibilityLabel("\(selection.minutes) minutes")
                }
                .frame(maxWidth: 500)
            }
            if let error = manager.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: manager.isActive)
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
    }

    private func start() { manager.start() }
    private func togglePause() {
        if manager.session.state == .paused { manager.resume() } else { manager.pause() }
    }
    private func selectMode(_ mode: FocusSessionMode) {
        guard selection.mode != mode else { return }
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.94)) { selection.mode = mode }
        FocusHaptics.action()
    }
}
