//
//  MediaSettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import AppKit
import Defaults
import SwiftUI

struct MediaSettingsView: View {
    @Default(.waitInterval) var waitInterval
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles
    @Default(.sliderColor) var sliderColor

    @Default(.enableLyrics) var enableLyrics
    @ObservedObject private var musicManager = MusicManager.shared

    private var realtimeAudioWaveformSupported: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    var body: some View {
        Form {
            Section {
                Picker("Music Source", selection: mediaControllerSelection) {
                    ForEach(MediaControllerType.allCases) { controller in
                        Text(controller.localizedResource)
                            .tag(controller)
                            .disabled(
                                controller == .nowPlaying
                                    && !musicManager.nowPlayingAvailability.isSelectable
                            )
                    }
                }
            } header: {
                Text("Media Source")
            } footer: {
                mediaSourceFooter
            }

            Section {
                Toggle(
                    "Show music live activity",
                    isOn: $coordinator.musicLiveActivityEnabled.animation()
                )
                Toggle("Show sneak peek on playback changes", isOn: $enableSneakPeek)
                Picker("Sneak Peek Style", selection: $sneakPeekStyles) {
                    ForEach(SneakPeekStyle.allCases) { style in
                        Text(style.localizedString).tag(style)
                    }
                }
                HStack {
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("Media inactivity timeout")
                            Spacer()
                            Text(
                                Measurement(
                                    value: Defaults[.waitInterval],
                                    unit: UnitDuration.seconds
                                ),
                                format: .measurement(
                                    width: .wide,
                                    usage: .asProvided,
                                    numberFormatStyle: .number.precision(
                                        .fractionLength(0)
                                    )
                                )
                            )
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker(
                    selection: $hideNotchOption,
                    label:
                        HStack {
                            Text("Full screen behavior")
                            customBadge(text: "Beta")
                        }
                ) {
                    Text("Hide for all apps").tag(HideNotchOption.always)
                    Text("Hide for media app only").tag(
                        HideNotchOption.nowPlayingOnly)
                    Text("Never hide").tag(HideNotchOption.never)
                }
            } header: {
                Text("Media playback live activity")
            }

            Section {
                MusicSlotConfigurationView()
                Defaults.Toggle(key: .enableLyrics) {
                    HStack {
                        Text("Show lyrics below artist name")
                        customBadge(text: "Beta")
                    }
                }
                Defaults.Toggle(key: .romanizeLyrics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Romanise Hindi, Punjabi and Urdu lyrics")
                        Text("Keep the original words in Latin letters, such as दिल → dil. Urdu spelling may be approximate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!enableLyrics)
                Defaults.Toggle(key: .showRemainingTime) {
                    Text("Show remaining time instead of duration")
                }
            } header: {
                Text("Media controls")
            }  footer: {
                Text("Customize which controls appear in the music player. Volume expands when active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .coloredSpectrogram) {
                    Text("Colored spectrogram")
                }
                Defaults.Toggle(key: .realtimeAudioWaveform) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Real-time audio waveform")
                        Group {
                            if realtimeAudioWaveformSupported {
                                Text("Uses Accelerate FFT on the playing app's audio. Requires audio capture permission and uses slightly more CPU.")
                            } else {
                                Text("Requires macOS 14.2 or later. Update macOS to enable real-time audio waveform.")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(!realtimeAudioWaveformSupported)
                Defaults.Toggle(key: .playerColorTinting) {
                    Text("Player tinting")
                }
                Defaults.Toggle(key: .lightingEffect) {
                    Text("Enable blur effect behind album art")
                }
                Picker("Slider color", selection: $sliderColor) {
                    ForEach(SliderColorEnum.allCases, id: \.self) { option in
                        Text(option.localizedString)
                    }
                }
            } header: {
                Text("Player appearance")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Media")
        .task {
            musicManager.ensureNowPlayingAvailabilityChecked()
        }
        .onChange(of: enableLyrics) { _, enabled in
            if enabled {
                Task {
                    await LyricsService.shared.fetchLyrics(
                        bundleIdentifier: musicManager.bundleIdentifier,
                        title: musicManager.songTitle,
                        artist: musicManager.artistName,
                        preferProvider: musicManager.effectiveMediaController == .octave
                    )
                }
            } else {
                LyricsService.shared.clearLyrics()
            }
        }
    }

    private var mediaControllerSelection: Binding<MediaControllerType> {
        Binding(
            get: { musicManager.preferredMediaController },
            set: { selectedController in
                guard selectedController != musicManager.preferredMediaController else { return }
                musicManager.selectMediaController(selectedController)
            }
        )
    }

    @ViewBuilder
    private var mediaSourceFooter: some View {
        let availability = musicManager.nowPlayingAvailability

        if musicManager.preferredMediaController == .octave {
            VStack(alignment: .leading, spacing: 6) {
                footerText("Load the bundled Octave bridge as an unpacked extension in Brave, then reload the Octave tab. The extension only runs on music.octavestreaming.com.")
                Button("Show Brave extension folder") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("octave-brave-extension", isDirectory: true) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
            }
        } else if musicManager.preferredMediaController != .nowPlaying {
            EmptyView()
        } else if availability == .checking {
            footerText("Checking Now Playing availability...")
        } else if let message = availability.settingsMessage {
            VStack(alignment: .leading, spacing: 6) {
                footerText(message)

                if musicManager.preferredMediaController == .nowPlaying,
                   let effectiveController = musicManager.effectiveMediaController,
                   effectiveController != .nowPlaying {
                    if availability.usesTemporaryFallback {
                        footerText(
                            LocalizedStringResource(
                                "Using \(effectiveController.localizedString) temporarily. Your Now Playing preference is preserved.",
                                comment: "Media settings footer for a temporary Now Playing fallback. The placeholder is the active fallback source."
                            )
                        )
                    } else {
                        footerText(
                            LocalizedStringResource(
                                "Using \(effectiveController.localizedString) instead. Your Now Playing preference is preserved.",
                                comment: "Media settings footer for a non-recoverable Now Playing setup failure. The placeholder is the active fallback source."
                            )
                        )
                    }
                }

                if availability.offersManualRetry {
                    Button("Check Again") {
                        musicManager.refreshNowPlayingAvailability()
                    }
                    .font(.caption)
                }
            }
        } else {
            footerText(
                "'Now Playing' was the only option on previous versions and works with all media apps."
            )
        }
    }

    private func footerText(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.caption)
    }
}
