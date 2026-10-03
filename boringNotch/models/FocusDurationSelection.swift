import Combine

@MainActor
final class FocusDurationSelection: ObservableObject {
    @Published var minutes = 25
    @Published var mode: FocusSessionMode = .timer
}
