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

    private let bridge: OctaveSocketBridge
    private let reconnectGrace: Duration
    private var disconnectExpiry: Task<Void, Never>?
    private var sequence = 0
    private var artworkURL: String?
    private var artworkTask: Task<Void, Never>?
    private var currentTrack = ""
    private var lastPositionPublish = Date.distantPast

    init(bridge: OctaveSocketBridge? = nil, reconnectGrace: Duration = .seconds(5)) {
        self.bridge = bridge ?? .shared
        let bridge = self.bridge
        self.reconnectGrace = reconnectGrace
        bridge.onMessage = { [weak self] message in self?.receive(message) }
        bridge.onDisconnect = { [weak self] reason in self?.transportInterrupted(reason: reason) }
        bridge.start()
    }

    deinit {
        artworkTask?.cancel()
        disconnectExpiry?.cancel()
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
    func isActive() -> Bool { bridge.isConnected || disconnectExpiry != nil }

    private func transportInterrupted(reason: String) {
        NSLog("Octave transport interrupted: %@", reason)
        // Reconnecting alone is insufficient: expire unless fresh playback data arrives.
        disconnectExpiry?.cancel()
        disconnectExpiry = Task { [weak self, reconnectGrace] in
            do { try await Task.sleep(for: reconnectGrace) } catch { return }
            guard !Task.isCancelled else { return }
            self?.clearState()
        }
    }
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
        disconnectExpiry?.cancel()
        disconnectExpiry = nil
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
        let rate = message["rate"] as? Double ?? 1
        state.playbackRate = rate.isFinite && rate >= 0 ? rate : 1
        state.isShuffled = message["shuffle"] as? Bool ?? false
        state.isSmartShuffled = message["smartShuffle"] as? Bool ?? false
        state.bundleIdentifier = MediaAppBundleID.brave
        state.audioCaptureBundleIdentifiers = [MediaAppBundleID.braveAudioHelper, MediaAppBundleID.brave]
        let now = Date()
        let sampleDate = LyricPlaybackClock.sampleDate(milliseconds: message["sampledAt"] as? Double, receivedAt: now)
        let meaningfulPosition = trackChanged || message["clockDiscontinuity"] as? Bool == true || LyricPlaybackClock.needsCorrection(
            position: state.currentTime, sampleDate: sampleDate,
            anchorPosition: playbackState.currentTime, anchorDate: playbackState.lastUpdated,
            rate: playbackState.playbackRate, playing: playbackState.isPlaying)
            || playing && now.timeIntervalSince(lastPositionPublish) >= 5
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
        disconnectExpiry?.cancel()
        disconnectExpiry = nil
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
final class OctaveSocketBridge {
    static let shared = OctaveSocketBridge()
    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private let writeQueue = DispatchQueue(label: "Octave.socket.writes")
    private var connectionID: UUID?
    private(set) var isConnected = false
    private var server: Int32 = -1
    private var client: Int32 = -1
    private var stopped = false
    private var references = 0
    private let path: String

    init(path: String? = nil) {
        self.path = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BoringNotchLocal/octave.sock").path
    }

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
        let descriptor = Darwin.dup(server)
        guard descriptor >= 0 else { Darwin.close(server); server = -1; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { Darwin.close(descriptor) }
            while true {
                let accepted = Darwin.accept(descriptor, nil, nil)
                if accepted < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let connectionID = UUID()
                var noSignal: Int32 = 1
                setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(accepted, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                Task { @MainActor [weak self] in self?.connected(accepted, id: connectionID) }
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                var reason = "peer closed the connection"
                while true {
                    let count = Darwin.read(accepted, &buffer, buffer.count)
                    if count < 0 {
                        if errno == EINTR { continue }
                        reason = "read failed (errno \(errno))"
                        break
                    }
                    if count == 0 { break }
                    pending.append(contentsOf: buffer[..<count])
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending[..<newline]
                        pending.removeSubrange(...newline)
                        if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                            Task { @MainActor [weak self] in self?.received(object, id: connectionID) }
                        }
                    }
                    if pending.count > 2_000_000 { reason = "unterminated message exceeded 2 MB"; break }
                }
                let disconnectReason = reason
                Task { @MainActor [weak self] in
                    Darwin.close(accepted)
                    self?.disconnected(id: connectionID, reason: disconnectReason)
                }
            }
        }
    }

    private func connected(_ descriptor: Int32, id: UUID) {
        guard !stopped else { Darwin.shutdown(descriptor, SHUT_RDWR); return }
        client = descriptor
        connectionID = id
        isConnected = true
    }

    private func received(_ object: [String: Any], id: UUID) {
        guard connectionID == id, !stopped else { return }
        onMessage?(object)
    }

    private func disconnected(id: UUID, reason: String) {
        guard connectionID == id else { return }
        client = -1
        connectionID = nil
        isConnected = false
        onDisconnect?(reason)
    }

    func send(_ object: [String: Any]) {
        guard client >= 0, let id = connectionID,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        // The reader owns the original descriptor; dup prevents reuse while a write is queued.
        let descriptor = Darwin.dup(client)
        guard descriptor >= 0 else {
            Darwin.shutdown(client, SHUT_RDWR)
            disconnected(id: id, reason: "could not duplicate command socket (errno \(errno))")
            return
        }
        var payload = data
        payload.append(10)
        writeQueue.async { [weak self, payload] in
            defer { Darwin.close(descriptor) }
            if let error = OctaveSocketWriter.writeAll(payload, to: descriptor) {
                Task { @MainActor [weak self] in self?.writeFailed(id: id, reason: error) }
            }
        }
    }
    private func writeFailed(id: UUID, reason: String) {
        guard connectionID == id else { return }
        let descriptor = client
        // Publish the write failure before waking the reader with a synthetic EOF.
        disconnected(id: id, reason: reason)
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    func stop() {
        references = max(0, references - 1)
        guard references == 0 else { return }
        stopped = true
        if client >= 0 { Darwin.shutdown(client, SHUT_RDWR); client = -1 }
        connectionID = nil
        isConnected = false
        if server >= 0 { Darwin.shutdown(server, SHUT_RDWR); Darwin.close(server); server = -1 }
        unlink(path)
        onMessage = nil
        onDisconnect = nil
    }
}

/// A stream write can succeed with fewer bytes than requested.
enum OctaveSocketWriter {
    static func writeAll(_ data: Data, to descriptor: Int32,
                         write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }) -> String? {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return "command write failed (errno \(count == 0 ? 0 : errno))" }
                offset += count
            }
            return nil
        }
    }
}
