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
    first.setCaptureDemand(true)
    second.setCaptureDemand(true)
    first.setPlaying(true)
    second.setPlaying(true)
    first.attach(to: manager)
    second.attach(to: manager)
    precondition(manager.consumers.isEmpty, "Detached views must not request capture")
    window.contentView?.addSubview(first)
    window.contentView?.addSubview(second)
    precondition(manager.consumers.count == 2,
                 "Realtime demand must register before capture reports itself active")
    first.setUseRealtime(true)
    second.setUseRealtime(true)
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

    let decorative = MusicVisualizerModel(frame: CGRect(x: 0, y: 0, width: 20, height: 14))
    decorative.attach(to: manager)
    decorative.setReduceMotion(true)
    window.contentView?.addSubview(decorative)
    decorative.setPlaying(true)
    precondition(manager.consumers.isEmpty, "Idle animation must not request audio capture")
    precondition(decorative.layer?.sublayers?.allSatisfy {
        $0.animation(forKey: "scaleAnimation") == nil
    } == true, "Reduce Motion must suppress random bar animations")
    decorative.setReduceMotion(false)
    precondition(decorative.layer?.sublayers?.contains {
        $0.animation(forKey: "scaleAnimation") != nil
    } == true, "Random animation should resume when Reduce Motion is off")
    decorative.setCaptureDemand(true)
    precondition(manager.consumers.count == 1, "Realtime preference must request capture before rendering switches modes")
    decorative.setUseRealtime(true)
    precondition(manager.consumers.count == 1, "Realtime waveform should retain its capture consumer")
    decorative.setReduceMotion(true)
    precondition(manager.consumers.count == 1, "Reduce Motion must preserve the selected realtime waveform")
    precondition(decorative.layer?.sublayers?.allSatisfy {
        $0.animation(forKey: "scaleAnimation") == nil
    } == true)
    decorative.setPlaying(false)
    precondition(manager.consumers.isEmpty, "Stopped waveform must release capture demand")
    decorative.detach()
    print("PASS visible capture consumers and Reduce Motion animation/capture behavior")
}
