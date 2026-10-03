import SwiftUI

struct FocusActivityView: View {
    @ObservedObject private var manager = FocusSessionManager.shared
    @ViewState private var controlsVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var width: CGFloat
    var height: CGFloat
    var expanded: Bool
    let open: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: manager.session.state == .paused)) { context in
            let remaining = manager.session.remaining(at: context.date)
            let progress = manager.session.progress(at: context.date)
            ZStack {
                Button(action: open) {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().stroke(.orange.opacity(0.2), lineWidth: 1.5)
                            Circle().trim(from: 0, to: progress)
                                .stroke(.orange.opacity(manager.session.state == .paused ? 0.5 : 0.95), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: manager.session.state == .paused ? "pause.fill" : manager.session.mode.symbol)
                                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.orange)
                        }
                        .frame(width: 20, height: 20)
                        // Keep the digits alive when compacting to icon-only.
                        Text(FocusSessionSnapshot.timeText(remaining))
                            .font(Font(FocusActivityMetrics.font))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: Int(ceil(remaining)))
                            .foregroundStyle(.orange)
                            .fixedSize()
                            .frame(width: width >= 70 ? max(0, width - 42) : 0, alignment: .leading)
                            .clipped()
                            .opacity(width >= 70 ? 1 : 0)
                    }
                    .frame(width: max(0, width - 16), height: height)
                    .contentShape(Capsule())
                }
                .animation(reduceMotion ? nil : StandardAnimations.focusTab) { content in
                    content.opacity(controlsVisible ? 0 : 1).offset(y: controlsVisible ? -6 : 0)
                }
                .allowsHitTesting(!controlsVisible)
                .accessibilityHidden(controlsVisible)
                .accessibilityLabel("\(manager.session.mode.title), \(FocusSessionSnapshot.timeText(remaining)) remaining\(manager.session.state == .paused ? ", paused" : "")")
                .help("Open \(manager.session.mode.title)")

                HStack(spacing: 3) {
                    Button(action: togglePause) {
                        Image(systemName: manager.session.state == .paused ? "play.fill" : "pause.fill")
                            .frame(width: 29, height: max(24, height - 4))
                            .contentShape(Capsule())
                    }
                    .accessibilityLabel(manager.session.state == .paused ? "Resume session" : "Pause session")
                    .help(manager.session.state == .paused ? "Resume" : "Pause")
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 0.5, height: 12)
                    Button(action: manager.cancel) {
                        Image(systemName: "xmark")
                            .frame(width: 29, height: max(24, height - 4))
                            .contentShape(Capsule())
                    }
                    .accessibilityLabel("Cancel session")
                    .help("Cancel")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .animation(reduceMotion ? nil : StandardAnimations.focusTab) { content in
                    content.opacity(controlsVisible ? 1 : 0).offset(y: controlsVisible ? 0 : 8)
                }
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
            }
            .buttonStyle(.plain)
            .frame(width: width, height: height)
            .background(.black, in: Capsule())
            .overlay(alignment: .top) {
                Capsule().fill(.white.opacity(0.08)).frame(width: max(0, width - 22), height: 0.5).padding(.top, 1)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onHover { hovering in controlsVisible = expanded && hovering }
            .onChange(of: expanded) { _, _ in controlsVisible = false }
        }
    }

    private func togglePause() {
        if manager.session.state == .paused { manager.resume() } else { manager.pause() }
    }
}
