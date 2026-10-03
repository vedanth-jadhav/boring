import Combine
import Foundation

/// The shell only needs availability and playback status. Clock anchors,
/// volume and artwork updates belong to the media views that consume them.
@MainActor
final class NotchMusicState: ObservableObject {
    struct Snapshot: Equatable {
        let isPlaying: Bool
        let isPlayerIdle: Bool
        let notice: NowPlayingFallbackNotice?
    }

    @Published private(set) var snapshot: Snapshot
    private var subscription: AnyCancellable?

    convenience init() { self.init(music: .shared) }

    init(music: MusicManager) {
        snapshot = Snapshot(isPlaying: music.isPlaying, isPlayerIdle: music.isPlayerIdle, notice: music.nowPlayingNotice)
        subscription = Publishers.CombineLatest3(music.$isPlaying, music.$isPlayerIdle, music.$nowPlayingNotice)
            .map { Snapshot(isPlaying: $0, isPlayerIdle: $1, notice: $2) }
            .removeDuplicates()
            .sink { [weak self] value in
                guard self?.snapshot != value else { return }
                self?.snapshot = value
            }
    }
}
