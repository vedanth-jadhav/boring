import AudioToolbox
import CoreAudio
import Foundation

/// An output device's volume and mute, its stable UID and its name, so lid
/// open restores the device lid close muted even if the default output
/// changed in between, and a warning can name it (spec section 4).
struct AudioOutput: Equatable, Sendable {
    var deviceUID: String
    /// nil when the name could not be read.
    var name: String?
    var volume: Float
    var muted: Bool
}

/// Volume and mute of output devices, so lid close can mute and lid open
/// can restore exactly (spec section 4).
protocol AudioControlling: Sendable {
    /// The default output device now.
    func read() throws -> AudioOutput
    /// The device with this UID; throws `AudioDeviceMissingError` when it
    /// is not connected.
    func read(deviceUID: String) throws -> AudioOutput
    /// Sets the device with this UID, or the default output device when
    /// nil (a journal entry from a build that did not record the device).
    /// Throws `AudioDeviceMissingError` when no connected device has the UID.
    func apply(volume: Float, muted: Bool, deviceUID: String?) throws
    /// Mutes the device with this UID; throws `AudioDeviceMissingError`
    /// when it is not connected.
    func mute(deviceUID: String) throws
    /// Calls `handler` on the main queue each time a device connects or
    /// disconnects, for the life of the process.
    func onDevicesChanged(_ handler: @escaping @Sendable () -> Void) throws
}

struct AudioControlError: Error, LocalizedError, Sendable {
    let what: String
    let status: OSStatus

    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

/// The output device a journal entry is for is not connected.
struct AudioDeviceMissingError: Error, LocalizedError, Sendable {
    let deviceUID: String

    var errorDescription: String? { "output device \(deviceUID) is not connected" }
}

/// Does nothing; the default for SessionManager so tests and non-audio
/// paths need no CoreAudio.
struct NoopAudioControl: AudioControlling {
    func read() throws -> AudioOutput { AudioOutput(deviceUID: "none", volume: 1, muted: false) }
    func read(deviceUID: String) throws -> AudioOutput { AudioOutput(deviceUID: deviceUID, volume: 1, muted: false) }
    func apply(volume: Float, muted: Bool, deviceUID: String?) throws {}
    func mute(deviceUID: String) throws {}
    func onDevicesChanged(_ handler: @escaping @Sendable () -> Void) throws {}
}

/// CoreAudio implementation: reads the default output device, and reads
/// and sets the device a UID names.
struct CoreAudioControl: AudioControlling {
    func read() throws -> AudioOutput {
        try output(of: defaultOutputDevice())
    }

    func read(deviceUID: String) throws -> AudioOutput {
        try output(of: device(withUID: deviceUID))
    }

    func apply(volume: Float, muted: Bool, deviceUID: String?) throws {
        let device = try deviceUID.map { try self.device(withUID: $0) } ?? defaultOutputDevice()
        var v = Float32(min(max(volume, 0), 1))
        try set(device, Self.volumeAddress, &v, "set volume")
        var m: UInt32 = muted ? 1 : 0
        try set(device, Self.muteAddress, &m, "set mute")
    }

    func mute(deviceUID: String) throws {
        let device = try device(withUID: deviceUID)
        var m: UInt32 = 1
        try set(device, Self.muteAddress, &m, "mute")
    }

    func onDevicesChanged(_ handler: @escaping @Sendable () -> Void) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            handler()
        }
        guard status == noErr else { throw AudioControlError(what: "watch output devices", status: status) }
    }

    // MARK: CoreAudio plumbing

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private func output(of device: AudioObjectID) throws -> AudioOutput {
        var volume: Float32 = 0
        try get(device, Self.volumeAddress, &volume, "read volume")
        var muted: UInt32 = 0
        try get(device, Self.muteAddress, &muted, "read mute")
        return AudioOutput(
            deviceUID: try string(kAudioDevicePropertyDeviceUID, of: device, "read device UID"),
            name: try? string(kAudioObjectPropertyName, of: device, "read device name"),
            volume: Float(volume),
            muted: muted != 0
        )
    }

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw AudioControlError(what: "default output device", status: status)
        }
        return device
    }

    private func string(_ selector: AudioObjectPropertySelector, of device: AudioObjectID, _ what: String) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr, let string = value?.takeRetainedValue() else {
            throw AudioControlError(what: what, status: status)
        }
        return string as String
    }

    /// The connected device with this UID. CoreAudio answers
    /// `kAudioObjectUnknown` for a UID no connected device has, which is
    /// the only answer that counts as not connected; a failed lookup throws
    /// its own error, so the caller keeps the entry for a retry either way
    /// but does not report a device as gone when it could not tell.
    private func device(withUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { q in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), q, &size, &device
            )
        }
        guard status == noErr else { throw AudioControlError(what: "look up output device", status: status) }
        guard device != kAudioObjectUnknown else { throw AudioDeviceMissingError(deviceUID: uid) }
        return device
    }

    private func get<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }

    private func set<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &value) { ptr in
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, UnsafeRawPointer(ptr))
        }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }
}
