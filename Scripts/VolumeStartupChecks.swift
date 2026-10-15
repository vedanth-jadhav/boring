import AppKit
import Combine
import CoreAudio
import Foundation

// These module-local HAL functions keep the real VolumeManager under test without changing audio.
private var fixtureVolume: Float32 = 0.25
private var fixtureMuted: UInt32 = 0
private var fixtureWrites = 0
private let scenario = CommandLine.arguments[1]

func AudioObjectHasProperty(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>) -> Bool {
    let property = address.pointee
    return property.mElement == kAudioObjectPropertyElementMain
        && (property.mSelector == kAudioDevicePropertyVolumeScalar
            || (property.mSelector == kAudioDevicePropertyMute && scenario != "software-mute"))
}

func AudioObjectGetPropertyDataSize(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                    _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                    _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    size.pointee = 4
    return noErr
}

func AudioObjectGetPropertyData(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                _ size: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutableRawPointer) -> OSStatus {
    switch address.pointee.mSelector {
    case kAudioHardwarePropertyDefaultOutputDevice:
        data.storeBytes(of: AudioObjectID(42), as: AudioObjectID.self)
    case kAudioDevicePropertyVolumeScalar:
        if scenario == "unreadable" { return kAudioHardwareUnspecifiedError }
        data.storeBytes(of: fixtureVolume, as: Float32.self)
    case kAudioDevicePropertyMute:
        data.storeBytes(of: fixtureMuted, as: UInt32.self)
    default:
        fatalError("Unexpected HAL property read")
    }
    return noErr
}

@discardableResult func AudioObjectSetPropertyData(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus {
    fixtureWrites += 1
    switch address.pointee.mSelector {
    case kAudioDevicePropertyVolumeScalar: fixtureVolume = data.load(as: Float32.self)
    case kAudioDevicePropertyMute: fixtureMuted = data.load(as: UInt32.self)
    default: fatalError("Unexpected HAL property write")
    }
    return noErr
}

func AudioObjectAddPropertyListenerBlock(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                         _ queue: DispatchQueue?, _ block: AudioObjectPropertyListenerBlock) -> OSStatus { noErr }
func AudioObjectRemovePropertyListenerBlock(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                            _ queue: DispatchQueue?, _ block: AudioObjectPropertyListenerBlock) -> OSStatus { noErr }

enum NotchUIEvent {
    enum Kind { case volume }
    case sneakPeek(type: Kind, value: CGFloat)
}
enum NotchUIEventBus {
    static let events = PassthroughSubject<NotchUIEvent, Never>()
}

@main struct VolumeStartupChecks {
    @MainActor static func main() async throws {
        let manager = VolumeManager.shared
        var shownVolumes: [CGFloat] = []
        let subscription = NotchUIEventBus.events.sink {
            if case let .sneakPeek(_, value) = $0 { shownVolumes.append(value) }
        }
        defer { subscription.cancel() }
        precondition(manager.rawVolume == 0, "The device read must still be awaiting main-thread publication")
        switch scenario {
        case "increase", "unreadable": manager.increase()
        case "repeat": manager.increase(); manager.increase(); manager.increase()
        case "decrease": manager.decrease()
        case "fine": manager.increase(stepDivisor: 4)
        case "mute", "software-mute": manager.toggleMuteAction()
        case "absolute": manager.setAbsolute(0.5)
        default: fatalError("Unknown scenario")
        }
        precondition(shownVolumes.isEmpty, "Controls must wait for real device state instead of using zero")
        try await Task.sleep(for: .milliseconds(250))
        let expected: Float32
        switch scenario {
        case "increase": expected = 0.3125
        case "repeat": expected = 0.4375
        case "decrease": expected = 0.1875
        case "fine": expected = 0.265625
        case "mute": expected = 0.25
        case "software-mute", "unreadable": expected = 0
        case "absolute": expected = 0.5
        default: fatalError("Unknown scenario")
        }
        precondition(manager.rawVolume == expected, "Incorrect first-use volume: \(manager.rawVolume), expected \(expected)")
        if scenario == "unreadable" {
            precondition(fixtureWrites == 0 && shownVolumes.isEmpty, "A failed read must not overwrite hardware with a zero-based target")
        } else {
            precondition(fixtureVolume == expected, "Hardware must receive the same target as the HUD")
            precondition(shownVolumes.count == (scenario == "repeat" ? 3 : 1), "Every queued key press must apply once")
        }
        if scenario == "mute" || scenario == "software-mute" {
            precondition(manager.isMuted, "First-use mute must use the fetched device capabilities")
            manager.toggleMuteAction()
            try await Task.sleep(for: .milliseconds(250))
            precondition(!manager.isMuted && manager.rawVolume == 0.25 && fixtureVolume == 0.25,
                         "Unmuting must restore the original volume")
        }
        print("PASS: volume startup \(scenario)")
    }
}
