import Foundation

enum FocusSessionMode: String, Codable, CaseIterable, Identifiable {
    case timer
    case caffeine

    var id: Self { self }
    var title: String { self == .timer ? "Timer" : "Caffeine" }
    var symbol: String { self == .timer ? "timer" : "cup.and.saucer.fill" }
}
