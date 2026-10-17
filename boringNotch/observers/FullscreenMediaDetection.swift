//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()

    @Published var fullscreenStatus: [String: Bool] = [:]

    private var monitorTask: Task<Void, Never>?
    private var policySubscription: AnyCancellable?
    private var latestSpaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var hideOption = Defaults[.hideNotchOption]
    private var musicSourceBundle: String?

    private init() {
        musicSourceBundle = MusicManager.shared.bundleIdentifier
        policySubscription = Publishers.CombineLatest(
            Defaults.publisher(.hideNotchOption).map(\.newValue).removeDuplicates(),
            MusicManager.shared.$bundleIdentifier.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] option, source in
            guard let self else { return }
            self.hideOption = option
            self.musicSourceBundle = source
            self.updateStatus()
        }
        startMonitoring()
    }

    deinit {
        monitorTask?.cancel()
    }

    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                guard !Task.isCancelled else { break }
                latestSpaces = spaces
                updateStatus()
            }
        }
    }

    private func updateStatus() {
        var newStatus: [String: Bool] = [:]

        for space in latestSpaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                if hideOption == .never {
                    shouldDetect = false
                } else if hideOption == .nowPlayingOnly, let musicSourceBundle {
                    shouldDetect = space.runningApps.contains(musicSourceBundle)
                } else {
                    shouldDetect = true
                }
                newStatus[uuid] = shouldDetect
            }
        }

        if fullscreenStatus != newStatus { fullscreenStatus = newStatus }
    }
}
