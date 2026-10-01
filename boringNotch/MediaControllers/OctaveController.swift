import AppKit
import Combine
import Darwin
import Foundation

/// Receives state from the Octave Brave extension and sends commands to its page.
/// The browser's audio element is the clock; no MediaRemote command is involved.
@MainActor
final class OctaveController: MediaControllerProtocol {
    @Published private(set) var playbackState = PlaybackState(bundleIdentifier: MediaAppBundleID.brave)
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    let supportsVolumeControl = true
    let supportsFavorite = false

    private let bridge = OctaveSocketBridge.shared
    private var sequence = 0
    private var artworkURL: String?
    private var artworkTask: Task<Void, Never>?
    private var currentTrack = ""
    private var lastPositionPublish = Date.distantPast

    init() {
        bridge.onMessage = { [weak self] message in self?.receive(message) }
        bridge.onDisconnect = { [weak self] in self?.clearState() }
        bridge.start()
    }

    deinit {
        artworkTask?.cancel()
        let bridge = bridge
        Task { @MainActor in bridge.stop() }
    }

    func play() async { bridge.send(["type": "command", "action": "play"]) }
    func pause() async { bridge.send(["type": "command", "action": "pause"]) }
    func togglePlay() async { if playbackState.isPlaying { await pause() } else { await play() } }
    func nextTrack() async { bridge.send(["type": "command", "action": "next"]) }
    func previousTrack() async { bridge.send(["type": "command", "action": "previous"]) }
    func seek(to time: Double) async {
        guard time.isFinite, time >= 0 else { return }
        sequence += 1
        bridge.send(["type": "command", "action": "seek", "position": time, "sequence": sequence])
    }
    func toggleShuffle() async { bridge.send(["type": "command", "action": "cycleShuffle"]) }
    func toggleRepeat() async {}
    func setVolume(_ level: Double) async {
        guard level.isFinite else { return }
        bridge.send(["type": "command", "action": "setVolume", "volume": min(1, max(0, level))])
    }
    func setFavorite(_ favorite: Bool) async {}
    func isActive() -> Bool { bridge.isConnected }
    func updatePlaybackInfo() async {}

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "gone": clearState()
        case "lyrics":
            guard let title = message["title"] as? String,
                  let artist = message["artist"] as? String,
                  let rows = message["lines"] as? [[String: Any]] else { return }
            let lines = rows.compactMap { row -> LyricLine? in
                guard let time = row["time"] as? Double, let text = row["text"] as? String else { return nil }
                let words = (row["words"] as? [[String: Any]] ?? []).compactMap { word -> LyricLine.Word? in
                    guard let text = word["text"] as? String, let start = word["start"] as? Double,
                          let end = word["end"] as? Double else { return nil }
                    return LyricLine.Word(text: text, start: start, end: end, isBackground: word["isBackground"] as? Bool ?? false)
                }
                return LyricLine(start: time, end: row["end"] as? Double, text: text, words: words, isBackground: row["isBackground"] as? Bool ?? false)
            }
            LyricsService.shared.setProviderLyrics(lines, plainLyrics: message["plainLyrics"] as? String ?? "",
                                                  title: title, artist: artist)
        case "state": receiveState(message)
        default: break
        }
    }

    private func receiveState(_ message: [String: Any]) {
        guard let title = message["title"] as? String,
              let position = message["position"] as? Double,
              let duration = message["duration"] as? Double,
              let playing = message["playing"] as? Bool,
              position.isFinite, duration.isFinite else { return }
        let artist = message["artist"] as? String ?? ""
        let track = "\(title)|\(artist)"
        var state = playbackState
        let trackChanged = track != currentTrack
        if trackChanged {
            currentTrack = track
            artworkTask?.cancel()
            artworkURL = nil
            // Keep the previous cover until the new one arrives. Clearing it
            // makes MusicManager briefly show the browser icon on every skip.
        }
        state.title = title
        state.artist = artist
        state.album = message["album"] as? String ?? ""
        state.currentTime = max(0, position)
        state.duration = max(0, duration)
        state.isPlaying = playing
        if let volume = message["volume"] as? Double, volume.isFinite {
            state.volume = min(1, max(0, volume))
        }
        state.playbackRate = message["rate"] as? Double ?? 1
        state.isShuffled = message["shuffle"] as? Bool ?? false
        state.isSmartShuffled = message["smartShuffle"] as? Bool ?? false
        state.bundleIdentifier = MediaAppBundleID.brave
        state.audioCaptureBundleIdentifiers = [MediaAppBundleID.braveAudioHelper, MediaAppBundleID.brave]
        let now = Date()
        let sampleDate = LyricPlaybackClock.sampleDate(milliseconds: message["sampledAt"] as? Double, receivedAt: now)
        let meaningfulPosition = trackChanged || LyricPlaybackClock.needsCorrection(
            position: state.currentTime, sampleDate: sampleDate,
            anchorPosition: playbackState.currentTime, anchorDate: playbackState.lastUpdated,
            rate: playbackState.playbackRate, playing: playbackState.isPlaying)
            || now.timeIntervalSince(lastPositionPublish) > 0.75
        let metadataChanged = state.title != playbackState.title || state.artist != playbackState.artist
            || state.album != playbackState.album || state.duration != playbackState.duration
            || state.isPlaying != playbackState.isPlaying || state.playbackRate != playbackState.playbackRate
            || state.isShuffled != playbackState.isShuffled
            || state.isSmartShuffled != playbackState.isSmartShuffled
            || state.volume != playbackState.volume
        if meaningfulPosition || metadataChanged {
            state.lastUpdated = sampleDate
            playbackState = state
            lastPositionPublish = now
        }
        if let source = message["artwork"] as? String, source != artworkURL,
           let url = URL(string: source), url.scheme == "https" {
            artworkURL = source
            artworkTask?.cancel()
            artworkTask = Task { [weak self] in
                guard let self else { return }
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count < 5_000_000, !Task.isCancelled,
                      self.currentTrack == track, self.artworkURL == source else { return }
                var updated = self.playbackState
                updated.artwork = data
                self.playbackState = updated
            }
        }
    }

    private func clearState() {
        artworkTask?.cancel()
        artworkURL = nil
        currentTrack = ""
        var state = PlaybackState(bundleIdentifier: MediaAppBundleID.brave)
        state.audioCaptureBundleIdentifiers = [MediaAppBundleID.braveAudioHelper, MediaAppBundleID.brave]
        state.lastUpdated = Date()
        playbackState = state
    }
}

@MainActor
private final class OctaveSocketBridge {
    static let shared = OctaveSocketBridge()
    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var isConnected = false
    private var server: Int32 = -1
    private var client: Int32 = -1
    private var stopped = false
    private var references = 0
    private let path: String = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BoringNotchLocal", isDirectory: true)
        return directory.appendingPathComponent("octave.sock").path
    }()

    func start() {
        references += 1
        guard server < 0 else { return }
        stopped = false
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { return }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(server); server = -1; return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(server, 1) == 0 else { Darwin.close(server); server = -1; return }
        chmod(path, 0o600)
        let descriptor = server
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let accepted = Darwin.accept(descriptor, nil, nil)
                if accepted < 0 {
                    if errno == EINTR { continue }
                    return
                }
                Task { @MainActor [weak self] in self?.connected(accepted) }
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(accepted, &buffer, buffer.count)
                    if count <= 0 { break }
                    pending.append(contentsOf: buffer[..<count])
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending[..<newline]
                        pending.removeSubrange(...newline)
                        if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                            Task { @MainActor [weak self] in self?.onMessage?(object) }
                        }
                    }
                    if pending.count > 2_000_000 { break }
                }
                Darwin.close(accepted)
                Task { @MainActor [weak self] in self?.disconnected(accepted) }
            }
        }
    }

    private func connected(_ descriptor: Int32) {
        guard !stopped else { Darwin.close(descriptor); return }
        if client >= 0 && client != descriptor { Darwin.close(client) }
        client = descriptor
        isConnected = true
    }
    private func disconnected(_ descriptor: Int32) {
        guard client == descriptor else { return }
        client = -1
        isConnected = false
        onDisconnect?()
    }
    func send(_ object: [String: Any]) {
        guard client >= 0,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var payload = data
        payload.append(10)
        payload.withUnsafeBytes { buffer in
            guard let pointer = buffer.baseAddress else { return }
            _ = Darwin.write(client, pointer, buffer.count)
        }
    }
    func stop() {
        references = max(0, references - 1)
        guard references == 0 else { return }
        stopped = true
        if client >= 0 { Darwin.close(client); client = -1 }
        if server >= 0 { Darwin.close(server); server = -1 }
        unlink(path)
        onMessage = nil
        onDisconnect = nil
    }
}
