import AppKit
import Combine
import Foundation

final class XPCHelperClient {
    static let shared = XPCHelperClient()
    var hardware: Float = 0.2
    var writes: [Float] = []
    var activeWrites = 0
    var maximumActiveWrites = 0
    var failNextWrite = false
    @MainActor func currentScreenBrightness() async -> Float? {
        let snapshot = hardware
        try? await Task.sleep(for: .milliseconds(350))
        return snapshot
    }
    @MainActor func setScreenBrightness(_ value: Float) async -> Bool {
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        try? await Task.sleep(for: .milliseconds(80))
        writes.append(value)
        activeWrites -= 1
        if failNextWrite {
            failNextWrite = false
            return false
        }
        hardware = value
        return true
    }
    @MainActor func adjustScreenBrightness(by delta: Float) async -> Float? {
        let target = max(0, min(1, hardware + delta))
        _ = await setScreenBrightness(target)
        return target
    }
    func displayIDForBrightness() async -> CGDirectDisplayID? { nil }
    func currentKeyboardBrightness() async -> Float? { 0.5 }
    func setKeyboardBrightness(_ value: Float) async -> Bool { true }
}
extension NSScreen {
    var cgDisplayID: CGDirectDisplayID { 0 }
    var displayUUID: String? { "fixture-screen" }
}
enum NotchUIEvent {
    enum Kind { case brightness, backlight }
    case sneakPeek(type: Kind, value: CGFloat, targetScreenUUID: String? = nil)
}
enum NotchUIEventBus { static let events = PassthroughSubject<NotchUIEvent, Never>() }

@main struct BrightnessCoalescingChecks {
    @MainActor static func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
    @MainActor static func main() async throws {
        let manager = BrightnessManager.shared
        let client = XPCHelperClient.shared
        await Task.yield() // Let the deliberately delayed startup read begin.
        for index in 0...100 { manager.setAbsolute(value: Float(index) / 100) }
        precondition(manager.rawBrightness == 1, "Dragging must publish the latest intent immediately")
        try await settle()
        precondition(client.writes == [1], "One burst of slider input must produce one final hardware write")
        precondition(manager.rawBrightness == 1, "A stale startup read must not overwrite a newer slider value")

        client.writes.removeAll()
        manager.setAbsolute(value: 0.1)
        try await Task.sleep(for: .milliseconds(90)) // First write is now in flight.
        for index in 2...8 { manager.setAbsolute(value: Float(index) / 10) }
        try await settle()
        precondition(client.writes == [0.1, 0.8] && client.hardware == 0.8,
                     "Changes during an RPC must retain only the latest target and flush it")
        precondition(client.maximumActiveWrites == 1, "Brightness RPCs must never overlap")

        manager.setAbsolute(value: 0.4)
        manager.setRelative(delta: 0.1)
        manager.setRelative(delta: 0.1)
        try await settle()
        precondition(abs(client.hardware - 0.6) < 0.0001, "Key repeats after a pending slider value must be preserved")
        manager.setRelative(delta: -0.1)
        manager.setAbsolute(value: 0.3)
        try await settle()
        precondition(client.hardware == 0.3, "A newer absolute target must supersede queued deltas")
        client.failNextWrite = true
        manager.setAbsolute(value: 0.9)
        try await Task.sleep(for: .milliseconds(650))
        precondition(client.hardware == 0.3 && manager.rawBrightness == 0.3,
                     "A failed optimistic slider write must refresh the actual device value")
        print("PASS: brightness burst coalescing, final flush, ordered keys, single RPC, and stale-read protection")
    }
}
