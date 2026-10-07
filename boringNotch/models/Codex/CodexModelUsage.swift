import Foundation

struct CodexModelUsage: Identifiable, Sendable {
    let id: String
    let tokens: CodexTokenTotals
    let rate: CodexRateCatalog.Rate?
    var estimate: Double? { rate?.estimate(tokens) }
}

enum CodexUsagePeriod: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days"
    var id: String { rawValue }
    func start(at date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: self == .today ? 0 : self == .week ? -6 : -29, to: day) ?? day
    }
}
