import Combine

@MainActor
final class FocusDurationSelection: ObservableObject {
    @Published var minutes = 25
    @Published var caffeineReady = false
    @Published var caffeineSettingsOpen = false
    @Published var mode: FocusSessionMode = .timer

    func needsCaffeineSetup(isActive: Bool) -> Bool {
        mode == .caffeine && (caffeineSettingsOpen || (!isActive && !caffeineReady))
    }

    func completeCaffeineSetup() {
        caffeineReady = true
        caffeineSettingsOpen = false
    }
}
