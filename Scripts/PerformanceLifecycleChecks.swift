import AppKit
import Combine
import Foundation

@MainActor
func checkShellSubscription() {
    let music = MusicManager()
    let shell = NotchMusicState(music: music)
    var invalidations = 0
    let subscription = shell.objectWillChange.sink { invalidations += 1 }
    for index in 0..<100 {
        music.elapsedTime = Double(index)
        music.timestampDate = .now
        music.volume = Double(index) / 100
    }
    precondition(invalidations == 0, "Clock and volume must not invalidate the shell")
    music.isPlaying = true
    precondition(invalidations == 1 && shell.snapshot.isPlaying)
    music.isPlaying = true
    precondition(invalidations == 1, "Repeated playback state must be deduplicated")
    music.isPlayerIdle = false
    precondition(invalidations == 2 && !shell.snapshot.isPlayerIdle)
    music.nowPlayingNotice = NowPlayingFallbackNotice()
    precondition(invalidations == 3 && shell.snapshot.notice != nil)
    withExtendedLifetime(subscription) {}
    print("PASS shell ignores clock/volume and retains playback/notice updates")
}

@MainActor
func checkVisibleCaptureConsumers() {
    final class VisibilityWindow: NSWindow {
        var testVisible = true
        override var occlusionState: NSWindow.OcclusionState { testVisible ? [.visible] : [] }
    }
    let manager = AudioCaptureManager()
    let window = VisibilityWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 30),
        styleMask: [], backing: .buffered, defer: true)
    let first = MusicVisualizerModel(frame: CGRect(x: 0, y: 0, width: 20, height: 14))
    let second = MusicVisualizerModel(frame: CGRect(x: 30, y: 0, width: 20, height: 14))
    first.attach(to: manager)
    second.attach(to: manager)
    precondition(manager.consumers.isEmpty, "Detached views must not request capture")
    window.contentView?.addSubview(first)
    window.contentView?.addSubview(second)
    precondition(manager.consumers.count == 2)
    first.isHidden = true
    precondition(manager.consumers.count == 1, "One hidden view must retain the other consumer")
    second.removeFromSuperview()
    precondition(manager.consumers.isEmpty)
    first.isHidden = false
    precondition(manager.consumers.count == 1)
    window.testVisible = false
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    precondition(manager.consumers.isEmpty, "Occluded windows must release capture demand")
    window.testVisible = true
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    precondition(manager.consumers.count == 1)
    first.detach()
    precondition(manager.consumers.isEmpty, "Dismantling must release the final consumer")
    print("PASS capture consumers attach/hide/occlude/restore/dismantle")
}
