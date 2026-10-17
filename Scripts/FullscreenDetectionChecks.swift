import Foundation
import Combine
import Defaults
import MacroVisionKit

enum HideNotchOption: String, Defaults.Serializable { case always, nowPlayingOnly, never }
extension Defaults.Keys {
    static let hideNotchOption = Key<HideNotchOption>("fullscreen-detection-check-\(UUID().uuidString)", default: .always)
}
@MainActor final class MusicManager: ObservableObject {
    static let shared = MusicManager()
    @Published var bundleIdentifier: String?
}

@main struct FullscreenDetectionChecks {
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Fullscreen status did not update")
    }
    @MainActor static func main() async throws {
        defer { Defaults.reset(.hideNotchOption) }
        MusicManager.shared.bundleIdentifier = "player.one"
        await FullScreenMonitor.shared.emit([.init(runningApps: ["player.two"], screenUUID: "screen")])
        let detector = FullscreenMediaDetector.shared
        try await waitFor { detector.fullscreenStatus["screen"] == true }
        Defaults[.hideNotchOption] = .nowPlayingOnly
        try await waitFor { detector.fullscreenStatus["screen"] == false }
        MusicManager.shared.bundleIdentifier = "player.two"
        try await waitFor { detector.fullscreenStatus["screen"] == true }
        MusicManager.shared.bundleIdentifier = "player.one"
        try await waitFor { detector.fullscreenStatus["screen"] == false }
        Defaults[.hideNotchOption] = .always
        try await waitFor { detector.fullscreenStatus["screen"] == true }
        Defaults[.hideNotchOption] = .never
        try await waitFor { detector.fullscreenStatus["screen"] == false }
        var publications = 0
        let subscription = detector.$fullscreenStatus.dropFirst().sink { _ in publications += 1 }
        await FullScreenMonitor.shared.emit([.init(runningApps: ["player.two"], screenUUID: "screen")])
        try await Task.sleep(for: .milliseconds(50))
        precondition(publications == 0, "Identical fullscreen decisions must not invalidate the UI")
        await FullScreenMonitor.shared.emit([])
        try await waitFor { detector.fullscreenStatus.isEmpty }
        subscription.cancel()
        print("PASS: fullscreen setting changes, media-source changes, deduplication, and space removal")
    }
}
