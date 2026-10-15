import AppKit
import SwiftUI

// Deterministic data only; the views, native inputs, transitions and panel are production code.
@MainActor final class CaffeineSettings: ObservableObject {
    static let shared = CaffeineSettings()
    @Published var apps = [
        CaffeineAppChoice(id: "brave", name: "Brave Browser", url: URL(fileURLWithPath: "/Applications/Brave Browser.app"), icon: NSImage(), running: true, alwaysOn: false),
        CaffeineAppChoice(id: "terminal", name: "Terminal", url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), icon: NSImage(), running: true, alwaysOn: false)
    ]
    @Published var loading = false
    @Published var selected = Set<String>()
    var keptCount: Int { selected.count }
    func refresh() {}
    func isKept(_ app: CaffeineAppChoice) -> Bool { selected.contains(app.id) }
    func toggle(_ app: CaffeineAppChoice) { if !selected.insert(app.id).inserted { selected.remove(app.id) } }
    func keepAllRunning() { selected = Set(apps.map(\.id)) }
}

@MainActor final class FocusSessionManager: ObservableObject {
    static let shared = FocusSessionManager()
    let selection = FocusDurationSelection()
    @Published var isActive = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    func start() {}
}

@MainActor enum FocusHaptics {
    static func detent(major: Bool) {}
    static func action() {}
}
enum StandardAnimations { static let focusTab = Animation.spring(response: 0.22, dampingFraction: 0.94) }
enum FocusSessionSnapshot {
    static func timeText(_ seconds: TimeInterval) -> String { "\(Int(seconds) / 60):00" }
}
struct CaffeineOptionsView: View { let settings: CaffeineSettings; var body: some View { EmptyView() } }
struct FocusActiveSessionView: View { let editApps: () -> Void; var body: some View { EmptyView() } }
struct CaffeineAppSummary: View { let editing: Bool; let action: () -> Void; var body: some View { Button("Edit apps", action: action) } }
