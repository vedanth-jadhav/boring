import Defaults
import SwiftUI

/// SwiftUI observes every persisted preference as one reusable dynamic property.
struct CodexGlancePreferences: DynamicProperty {
    @Default(.codexUsageDisplay) var display
    @Default(.codexPillLimit) var outsideLimit
    @Default(.codexPillMetric) var outsideMetric
    @Default(.codexShowLimitLabel) var outsideShowsLabel
    @Default(.codexInsideMatchesPill) var insideMatchesPill
    @Default(.codexInsideLimit) var insideLimit
    @Default(.codexInsideMetric) var insideMetric
    @Default(.codexInsideShowLimitLabel) var insideShowsLabel

    var outside: CodexReadingConfiguration {
        .init(limit: outsideLimit, metric: outsideMetric, showsLabel: outsideShowsLabel)
    }

    var inside: CodexReadingConfiguration {
        if display == .pill && insideMatchesPill { return outside }
        return .init(limit: insideLimit, metric: insideMetric, showsLabel: insideShowsLabel)
    }

    func width(expanded: Bool) -> CGFloat {
        let reading = expanded ? inside : outside
        return CodexActivityMetrics.width(limit: reading.limit, metric: reading.metric, showsLabel: reading.showsLabel, expanded: expanded)
    }
}
