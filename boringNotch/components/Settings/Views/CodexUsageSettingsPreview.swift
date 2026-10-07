import SwiftUI

struct CodexUsageSettingsPreview: View {
    let display: CodexUsageDisplay
    let outside: CodexReadingConfiguration
    let inside: CodexReadingConfiguration

    var body: some View {
        VStack(spacing: 14) {
            if display == .pill {
                HStack(spacing: 6) {
                    Text("Closed").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).frame(width: 38, alignment: .leading)
                    NotchShape(topCornerRadius: 4, bottomCornerRadius: 10)
                        .fill(.black).frame(width: 98, height: 28)
                    CodexGlanceLabel(title: outside.limit.shortTitle, value: value(outside), secondaryValue: secondaryValue(outside), showsTitle: outside.showsLabel)
                        .frame(width: width(outside, expanded: false), height: 26)
                        .modifier(CodexActivitySurface(expanded: false))
                }
            }
            HStack(spacing: 6) {
                if display == .pill {
                    Text("Open").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).frame(width: 38, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Image(systemName: "house.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(width: 24)
                    Spacer(minLength: 8)
                    if display != .off {
                        CodexGlanceLabel(title: inside.limit.shortTitle, value: value(inside), secondaryValue: secondaryValue(inside), showsTitle: inside.showsLabel)
                            .frame(width: width(inside, expanded: true))
                    }
                    Image(systemName: "gear").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).frame(width: 24)
                }
                .padding(.horizontal, 14)
                .frame(width: display == .pill ? 276 : 320, height: 34)
                .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustrative preview. Outside: \(outside.limit.title), \(outside.metric.title). Inside: \(inside.limit.title), \(inside.metric.title).")
    }

    private func value(_ configuration: CodexReadingConfiguration) -> String {
        switch configuration.metric {
        case .reset: configuration.limit == .session ? "2h 30m" : "3d 4h"
        case .used: configuration.limit == .session ? "16% used" : "38% used"
        case .remaining, .remainingAndReset: configuration.limit == .session ? "84%" : "62%"
        }
    }

    private func secondaryValue(_ configuration: CodexReadingConfiguration) -> String? {
        configuration.metric == .remainingAndReset ? (configuration.limit == .session ? "2h 30m" : "3d 4h") : nil
    }

    private func width(_ configuration: CodexReadingConfiguration, expanded: Bool) -> CGFloat {
        CodexActivityMetrics.width(limit: configuration.limit, metric: configuration.metric, showsLabel: configuration.showsLabel, expanded: expanded)
    }
}
