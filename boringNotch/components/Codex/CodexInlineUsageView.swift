import Defaults
import SwiftUI

struct CodexInlineUsageView: View {
    var store = CodexUsageStore.shared
    var width: CGFloat = CodexActivityMetrics.headerWidth
    let open: () -> Void
    private var preferences = CodexGlancePreferences()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let reading = CodexGlanceReading(quota: store.quota, now: context.date, hasError: store.quotaError != nil, error: store.quotaError)
            let configuration = preferences.inside
            Button(action: open) {
                CodexGlanceLabel(title: configuration.limit.shortTitle, value: reading.value(for: configuration.limit, metric: configuration.metric),
                                 secondaryValue: reading.secondaryValue(for: configuration.limit, metric: configuration.metric),
                                 showsTitle: configuration.showsLabel, status: reading.state(for: configuration.limit))
                .frame(width: width, height: CodexActivityMetrics.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reading.accessibilityLabel(for: configuration.limit))
            .accessibilityHint("Open detailed Codex usage")
            .help(reading.help)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: store.quota?.updatedAt)
        }
    }
}
