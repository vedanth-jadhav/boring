import AppKit
import Combine
import Darwin
import Foundation
import ImageIO

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
    private let commandSession = UUID().uuidString
    private var artworkURL: String?
    private var artworkSources: [String] = []
    private var artworkRequestID: String?
    private var artworkTask: Task<Void, Never>?
    private let artworkSession: URLSession
    private let artworkCache = NSCache<NSString, NSData>()
    private var artworkRetryAfter = Date.distantPast
    private var currentTrack = ""
    private var lastPositionPublish = Date.distantPast

    init(bridge: OctaveSocketBridge? = nil, reconnectGrace: Duration = .seconds(5), artworkSession: URLSession = .shared) {
        self.bridge = bridge ?? .shared
        self.artworkSession = artworkSession
        artworkCache.countLimit = 24
        artworkCache.totalCostLimit = 16 * 1024 * 1024
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
        bridge.send(["type": "command", "action": "seek", "position": time, "sequence": sequence, "session": commandSession])
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
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil
        artworkRetryAfter = .distantPast
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
        case "artwork":
            guard let requestID = message["requestID"] as? String, requestID == artworkRequestID,
                  let source = message["url"] as? String, source == artworkURL,
                  let encoded = message["data"] as? String, encoded.count <= 400000,
                  let data = Data(base64Encoded: encoded), Self.isArtwork(data) else { return }
            artworkTask?.cancel()
            artworkTask = nil
            artworkRequestID = nil
            artworkCache.setObject(data as NSData, forKey: source as NSString, cost: data.count)
            var updated = playbackState
            updated.artwork = data
            if updated.artwork != playbackState.artwork { playbackState = updated }
        case "lyrics":
            guard let title = message["title"] as? String,
                  let artist = message["artist"] as? String,
                  title == playbackState.title, artist == playbackState.artist,
                  let rows = message["lines"] as? [[String: Any]] else { return }
            let lines = rows.compactMap { row -> LyricLine? in
                guard let time = row["time"] as? Double, time.isFinite, let text = row["text"] as? String else { return nil }
                let words = (row["words"] as? [[String: Any]] ?? []).compactMap { word -> LyricLine.Word? in
                    guard let text = word["text"] as? String, let start = word["start"] as? Double,
                          let end = word["end"] as? Double, start.isFinite, end.isFinite, end >= start else { return nil }
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
        let album = message["album"] as? String ?? ""
        let track = "\(message["trackID"] as? String ?? "")|\(title)|\(artist)|\(album)"
        var state = playbackState
        let trackChanged = track != currentTrack
        if trackChanged {
            currentTrack = track
            artworkTask?.cancel()
            artworkTask = nil
            artworkURL = nil
            artworkSources = []
            artworkRequestID = nil
            artworkRetryAfter = .distantPast
            // Keep the previous cover until the new one arrives. Clearing it
            // makes MusicManager briefly show the browser icon on every skip.
        }
        state.title = title
        state.artist = artist
        state.album = album
        let source = message["artwork"] as? String ?? ""
        let sources = Array((message["artworks"] as? [String] ?? [source]).filter { !$0.isEmpty }.prefix(8))
        let cachedArtwork = artworkCache.object(forKey: source as NSString) as Data?
        if let cachedArtwork { state.artwork = cachedArtwork }
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
        if meaningfulPosition || metadataChanged || state.artwork != playbackState.artwork {
            state.lastUpdated = sampleDate
            playbackState = state
            lastPositionPublish = now
        }
        if source != artworkURL || sources != artworkSources {
            artworkURL = source
            artworkSources = sources
            artworkRequestID = nil
            artworkTask?.cancel()
            artworkTask = nil
            artworkRetryAfter = .distantPast
        }
        if !source.isEmpty, cachedArtwork == nil, artworkTask == nil, now >= artworkRetryAfter {
            startArtworkFetch(sources: sources, source: source, track: track)
        }
    }

    private static func isArtwork(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count < 5_000_000,
              let image = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(image) > 0
    }

    private func requestBrowserArtwork(source: String) {
        guard artworkRequestID == nil else { return }
        let requestID = UUID().uuidString
        artworkRequestID = requestID
        bridge.send(["type": "command", "action": "requestArtwork", "url": source, "requestID": requestID])
    }

    private func startArtworkFetch(sources: [String], source: String, track: String) {
        let session = artworkSession
        artworkRequestID = nil
        let urls = sources.compactMap { URL(string: $0) }.filter { $0.scheme == "https" }
        if URL(string: source)?.scheme != "https" { requestBrowserArtwork(source: source) }
        if urls.isEmpty {
            requestBrowserArtwork(source: source)
            artworkRetryAfter = Date().addingTimeInterval(30)
            return
        }
        artworkTask = Task { [weak self] in
            let browserFallback = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.currentTrack == track, self.artworkURL == source else { return }
                self.requestBrowserArtwork(source: source)
            }
            defer { browserFallback.cancel() }
            for attempt in 0..<3 {
                if attempt > 0 {
                    do { try await Task.sleep(for: .milliseconds(attempt * 500)) } catch { return }
                }
                let cachePolicy: URLRequest.CachePolicy = attempt == 0 ? .returnCacheDataElseLoad : .reloadIgnoringLocalCacheData
                let url = urls[min(attempt, urls.count - 1)]
                var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 8)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                if let (data, response) = try? await session.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   Self.isArtwork(data) {
                    guard !Task.isCancelled, let self,
                          self.currentTrack == track, self.artworkURL == source else { return }
                    self.artworkCache.setObject(data as NSData, forKey: source as NSString, cost: data.count)
                    self.artworkTask = nil
                    self.artworkRequestID = nil
                    var updated = self.playbackState
                    updated.artwork = data
                    if updated.artwork != self.playbackState.artwork { self.playbackState = updated }
                    return
                }
                guard !Task.isCancelled else { return }
                if attempt == 0 { self?.requestBrowserArtwork(source: source) }
            }
            guard let self, self.currentTrack == track, self.artworkURL == source else { return }
            self.artworkTask = nil
            self.artworkRetryAfter = Date().addingTimeInterval(30)
        }
    }

    private func clearState() {
        disconnectExpiry?.cancel()
        disconnectExpiry = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        artworkSources = []
        artworkRequestID = nil
        artworkRetryAfter = .distantPast
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
    private var serverID = UUID()
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
        serverID = UUID()
        let serverID = serverID
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
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped, self.serverID == serverID else {
                        Darwin.close(accepted)
                        return
                    }
                    // A dead-but-open host must never hold the accept loop hostage.
                    if self.client >= 0 {
                        let notice = Data("{\"type\":\"superseded\"}\n".utf8)
                        notice.withUnsafeBytes { buffer in
                            _ = Darwin.send(self.client, buffer.baseAddress, buffer.count, MSG_DONTWAIT)
                        }
                        Darwin.shutdown(self.client, SHUT_RDWR)
                    }
                    self.client = accepted
                    self.connectionID = connectionID
                    self.isConnected = true
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        OctaveSocketBridge.readClient(accepted, id: connectionID, bridge: self)
                    }
                }
            }
        }
    }

    nonisolated private static func readClient(_ descriptor: Int32, id: UUID, bridge: OctaveSocketBridge?) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var reason = "peer closed the connection"
        readLoop: while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                reason = "read failed (errno \(errno))"
                break
            }
            if count == 0 { break }
            pending.append(contentsOf: buffer[..<count])
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                guard line.count <= 1_048_576 else { reason = "message exceeded 1 MB"; break readLoop }
                let data = Data(line)
                pending.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor [weak bridge] in bridge?.received(object, id: id) }
                }
            }
            if pending.count > 1_048_576 { reason = "unterminated message exceeded 1 MB"; break }
        }
        let disconnectReason = reason
        Task { @MainActor [weak bridge] in
            // Close on the same actor that duplicates this descriptor for writes.
            Darwin.close(descriptor)
            bridge?.disconnected(id: id, reason: disconnectReason)
        }
    }

    private func received(_ object: [String: Any], id: UUID) {
        guard connectionID == id, !stopped else { return }
        if object["type"] as? String == "ping", let nonce = object["nonce"] as? String {
            send(["type": "pong", "nonce": nonce])
            return
        }
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
