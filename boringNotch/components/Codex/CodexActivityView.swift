import Defaults
import SwiftUI

struct CodexActivityView: View {
    var store = CodexUsageStore.shared
    var width: CGFloat
    var height: CGFloat
    var expanded: Bool
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var preferences = CodexGlancePreferences()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let reading = CodexGlanceReading(quota: store.quota, now: context.date, hasError: store.quotaError != nil, error: store.quotaError)
            let configuration = expanded ? preferences.inside : preferences.outside
            Button(action: open) {
                CodexGlanceLabel(title: configuration.limit.shortTitle, value: reading.value(for: configuration.limit, metric: configuration.metric),
                                 secondaryValue: reading.secondaryValue(for: configuration.limit, metric: configuration.metric),
                                 showsTitle: configuration.showsLabel, status: reading.state(for: configuration.limit))
                .frame(width: width, height: height)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(CodexActivitySurface(expanded: expanded))
            .clipShape(Capsule())
            .environment(\.colorScheme, .dark)
            .accessibilityLabel(reading.accessibilityLabel(for: configuration.limit))
            .accessibilityHint("Open detailed Codex usage")
            .help(reading.help)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: store.quota?.updatedAt)
        }
    }
}
