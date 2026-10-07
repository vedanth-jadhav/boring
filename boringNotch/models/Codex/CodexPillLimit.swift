enum CodexPillLimit: String, CaseIterable, Identifiable {
    case session
    case weekly
    var id: Self { self }
    var title: String { self == .session ? "5-hour" : "Weekly" }
    var shortTitle: String { self == .session ? "5h" : "Weekly" }
}
