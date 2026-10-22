import Combine
import Foundation
import Darwin

@MainActor final class LyricsService {
    static let shared = LyricsService()
    func setProviderLyrics(_ lines: [LyricLine], plainLyrics: String, title: String, artist: String) {}
}

final class OctaveArtworkProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var data: Data
        var delay = 0.0
    }
    private static let lock = NSLock()
    private static var replies: [String: [Reply]] = [:]
    private static var counts: [String: Int] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    static func set(_ path: String, _ values: [Reply]) {
        lock.withLock { replies[path] = values; counts[path] = 0 }
    }
    static func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let reply: Reply = Self.lock.withLock {
            let count = Self.counts[path, default: 0]
            Self.counts[path] = count + 1
            let values = Self.replies[path]!
            return values[min(count, values.count - 1)]
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            stateLock.withLock {
                guard !stopped else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                               httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}

@main struct OctaveArtworkChecks {
    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), message)
        print("PASS: \(message)")
    }
    @MainActor static func main() async throws {
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        let otherImage = image + Data([0])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OctaveArtworkProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let socketPath = "/tmp/octave-artwork-\(UUID().uuidString).sock"
        let bridge = OctaveSocketBridge(path: socketPath)
        let controller = OctaveController(bridge: bridge, artworkSession: session)
        defer { bridge.stop(); session.invalidateAndCancel() }
        func send(_ title: String, _ path: String, position: Double = 12, playing: Bool = true) {
            bridge.onMessage?(["type": "state", "title": title, "artist": "Artist", "album": "Album",
                               "trackID": title, "position": position, "duration": 100.0, "playing": playing,
                               "artwork": path.isEmpty ? "" : "https://images.example" + path])
        }
        OctaveArtworkProtocol.set("/retry", [.init(status: 503, data: Data()), .init(data: image)])
        send("Retry", "/retry")
        try await wait("Artwork retries independently after an HTTP failure") { controller.playbackState.artwork == image }
        precondition(OctaveArtworkProtocol.count("/retry") == 2)
        OctaveArtworkProtocol.set("/next", [.init(data: otherImage, delay: 0.1)])
        send("Next", "/next")
        send("Next", "/next", position: 37, playing: false)
        try await wait("Artwork completion preserves the latest playback metadata") {
            controller.playbackState.artwork == otherImage && controller.playbackState.currentTime == 37 && !controller.playbackState.isPlaying
        }
        precondition(OctaveArtworkProtocol.count("/next") == 1, "In-flight requests are deduplicated")
        var publications = 0
        let subscription = controller.playbackStatePublisher.dropFirst().sink { _ in publications += 1 }
        send("Retry", "/retry")
        precondition(controller.playbackState.artwork == image && publications == 1, "Cached cover arrives with metadata in one publication")
        precondition(OctaveArtworkProtocol.count("/retry") == 2, "Cached artwork makes no network request")
        subscription.cancel()
        print("PASS: Cached artwork appears synchronously without another download")

        OctaveArtworkProtocol.set("/slow", [.init(data: otherImage, delay: 0.25)])
        send("Slow", "/slow")
        try await wait("Slow cover starts") { OctaveArtworkProtocol.count("/slow") == 1 }
        send("Retry", "/retry")
        try await Task.sleep(for: .milliseconds(350))
        precondition(controller.playbackState.title == "Retry" && controller.playbackState.artwork == image,
                     "Cancelled stale downloads cannot replace current artwork")
        print("PASS: Rapid skips reject stale artwork")

        OctaveArtworkProtocol.set("/invalid", [.init(data: Data("not an image".utf8)), .init(data: otherImage)])
        send("Invalid", "/invalid")
        try await wait("Malformed image data retries without replacing the displayed cover") {
            controller.playbackState.artwork == otherImage
        }
        precondition(OctaveArtworkProtocol.count("/invalid") == 2)

        OctaveArtworkProtocol.set("/broken-primary", [.init(status: 404, data: Data())])
        OctaveArtworkProtocol.set("/alternate", [.init(data: image)])
        bridge.onMessage?(["type": "state", "title": "Alternates", "artist": "Artist", "position": 1.0,
                           "duration": 100.0, "playing": true, "artwork": "https://images.example/broken-primary",
                           "artworks": ["https://images.example/broken-primary", "https://images.example/alternate"]])
        try await wait("A broken primary URL falls back to another cover size") { controller.playbackState.artwork == image }
        precondition(OctaveArtworkProtocol.count("/broken-primary") == 1 && OctaveArtworkProtocol.count("/alternate") == 1)

        let peer = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(peer) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(peer, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(connected == 0)
        try await wait("Browser-fallback command channel connects") { bridge.isConnected }
        let localSource = "blob:https://music.octavestreaming.com/cover"
        bridge.onMessage?(["type": "state", "title": "Local", "artist": "Artist", "position": 1.0,
                           "duration": 100.0, "playing": true, "artwork": localSource, "artworks": [localSource]])
        func nextCommand(_ description: String) async throws -> [String: Any] {
            var commandData = Data()
            var commandBuffer = [UInt8](repeating: 0, count: 4096)
            try await wait(description) {
                let count = Darwin.recv(peer, &commandBuffer, commandBuffer.count, MSG_DONTWAIT)
                if count > 0 { commandData.append(contentsOf: commandBuffer[..<count]) }
                return commandData.contains(10)
            }
            return try JSONSerialization.jsonObject(with: commandData.dropLast()) as! [String: Any]
        }
        let command = try await nextCommand("Browser-local artwork requests a page-side thumbnail")
        precondition(command["action"] as? String == "requestArtwork" && command["url"] as? String == localSource)
        let probe = Data("{\"type\":\"ping\",\"nonce\":\"round-trip-check\"}\n".utf8)
        let probeCount = probe.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, 0) }
        precondition(probeCount == probe.count)
        let pong = try await nextCommand("Native watchdog completes a real socket round trip")
        precondition(pong["type"] as? String == "pong" && pong["nonce"] as? String == "round-trip-check")
        precondition(controller.playbackState.title == "Local", "Transport probes do not change media state")
        bridge.onMessage?(["type": "artwork", "url": localSource, "requestID": "wrong", "data": otherImage.base64EncodedString()])
        precondition(controller.playbackState.artwork == image, "Unmatched browser responses cannot set artwork")
        bridge.onMessage?(["type": "artwork", "url": localSource, "requestID": command["requestID"]!, "data": otherImage.base64EncodedString()])
        precondition(controller.playbackState.artwork == otherImage, "The current browser thumbnail is accepted")
        print("PASS: Browser-local artwork and request identity validation")

        OctaveArtworkProtocol.set("/browser-wins", [.init(data: otherImage, delay: 1)])
        let started = Date()
        send("Slow network", "/browser-wins")
        let slowCommand = try await nextCommand("Slow native artwork triggers a browser-cache fallback")
        precondition(Date().timeIntervalSince(started) < 0.8, "Browser fallback must not wait for the network timeout")
        bridge.onMessage?(["type": "artwork", "url": slowCommand["url"]!, "requestID": slowCommand["requestID"]!,
                           "data": image.base64EncodedString()])
        try await Task.sleep(for: .milliseconds(1100))
        precondition(controller.playbackState.artwork == image, "Late native artwork cannot replace the accepted browser thumbnail")
        send("Invalid", "/invalid")
        precondition(controller.playbackState.artwork == otherImage)

        OctaveArtworkProtocol.set("/fail", [.init(status: 500, data: Data())])
        send("Failure", "/fail")
        try await wait("Artwork retries stop after three attempts") { OctaveArtworkProtocol.count("/fail") == 3 }
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<20 { send("Failure", "/fail") }
        try await Task.sleep(for: .milliseconds(100))
        precondition(OctaveArtworkProtocol.count("/fail") == 3, "Repeated playback snapshots respect failure backoff")

        OctaveArtworkProtocol.set("/clear", [.init(data: image, delay: 0.15)])
        send("Clear", "/clear")
        try await wait("Pending cover starts before source removal") { OctaveArtworkProtocol.count("/clear") == 1 }
        send("Clear", "")
        try await Task.sleep(for: .milliseconds(250))
        precondition(controller.playbackState.artwork == otherImage, "Removing the URL cancels the old request")
        bridge.onMessage?(["type": "gone"])
        precondition(controller.playbackState.title.isEmpty && controller.playbackState.artwork == nil)
        print("PASS: Failure backoff, missing URLs and explicit clearing")
        print("Octave artwork checks passed")
    }
}
