enum CodexPillMetric: String, CaseIterable, Identifiable {
    case remaining
    case used
    case reset
    case remainingAndReset
    var id: Self { self }
    var title: String {
        switch self {
        case .remaining: "Allowance left"
        case .used: "Usage used"
        case .reset: "Time until reset"
        case .remainingAndReset: "Allowance + reset time"
        }
    }
}
