import Foundation

enum CodexUsageDisplay: String, CaseIterable, Identifiable {
    case off
    case pill
    case text

    var id: Self { self }
    var title: String {
        switch self {
        case .off: "Off"
        case .pill: "Pill"
        case .text: "Text"
        }
    }
}
