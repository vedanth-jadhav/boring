enum CodexActivityConflict: String, CaseIterable, Identifiable {
    case oppositeSides
    case insideWhileFocusing
    var id: Self { self }
    var title: String {
        switch self {
        case .oppositeSides: "Keep both visible"
        case .insideWhileFocusing: "Codex inside only"
        }
    }
}
