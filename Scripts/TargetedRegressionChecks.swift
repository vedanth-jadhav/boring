import AppKit
import Combine
import Darwin
import OSLog
import Security
import UniformTypeIdentifiers

// Production client/controller/state implementations are compiled below; UI services are isolated.
enum Log {
    static let general = Logger(subsystem: "TargetedChecks", category: "general")
    static let shelf = Logger(subsystem: "TargetedChecks", category: "shelf")
}
@MainActor final class LyricsService {
    static let shared = LyricsService()
    func setProviderLyrics(_ lines: [LyricLine], plainLyrics: String, title: String, artist: String) {}
}
final class CredentialFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [SpicyLyricsCredential.LoadResult]
    private(set) var reads = 0
    init(_ outcomes: [SpicyLyricsCredential.LoadResult]) { self.outcomes = outcomes }
    func read() -> SpicyLyricsCredential.LoadResult {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
    }
}

@main struct TargetedRegressionChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await credentials()
        try await shelf()
        try await socket()
        print("Credential recovery, shelf mutation/import races, and socket reconnect/write checks passed.")
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        print("PASS: \(message)")
    }
    static func credentials() async throws {
        let value = "sl_sk_regression_fixture_123"
        let temporary = CredentialFixture([.inaccessible(errSecNotAvailable), .loaded(value)])
        let client = SpicyLyricsClient(credentialReader: { temporary.read() })
        let recovered = await client.credentialForRequest()
        check(recovered == value && temporary.reads == 2, "Temporary Keychain failure retries and recovers")
        let concurrentFixture = CredentialFixture([.inaccessible(errSecNotAvailable), .loaded(value)])
        let concurrentClient = SpicyLyricsClient(credentialReader: { concurrentFixture.read() })
        async let a = concurrentClient.credentialForRequest()
        async let b = concurrentClient.credentialForRequest()
        let both = await (a, b)
        check(both.0 == value && both.1 == value && concurrentFixture.reads == 2,
              "Concurrent song requests wait for the same recovering Keychain read")
        _ = await client.credentialForRequest()
        check(temporary.reads == 2, "Successfully loaded credentials are cached")
        let denied = CredentialFixture([.inaccessible(errSecInteractionNotAllowed), .loaded(value)])
        let authorizationClient = SpicyLyricsClient(credentialReader: { denied.read() })
        let first = await authorizationClient.credentialForRequest()
        let second = await authorizationClient.credentialForRequest()
        check(first == nil && second == nil && denied.reads == 1, "Authorization failures back off without repeated prompts")
        await authorizationClient.reloadCredential()
        let authorized = await authorizationClient.credentialForRequest()
        check(authorized == value, "Authorization reload retries the preserved credential")
        let missing = CredentialFixture([.missing, .loaded(value)])
        let missingClient = SpicyLyricsClient(credentialReader: { missing.read() })
        _ = await missingClient.credentialForRequest()
        await missingClient.reloadCredential()
        let saved = await missingClient.credentialForRequest()
        check(saved == value, "Missing credentials are refreshed after saving")
        let unavailable = CredentialFixture([.inaccessible(errSecNotAvailable)])
        let boundedClient = SpicyLyricsClient(credentialReader: { unavailable.read() })
        _ = await boundedClient.credentialForRequest()
        _ = await boundedClient.credentialForRequest()
        check(unavailable.reads == 3, "Temporary retries are bounded and subsequent requests back off")
        check(!SpicyLyricsCredential.requiresAuthorization(errSecNotAvailable), "Temporary failure does not claim an access permission problem")
        check(SpicyLyricsCredential.loadResult(service: "targeted-missing-" + UUID().uuidString) == .missing,
              "Actual Keychain item-not-found status stays distinct")
    }
    @MainActor static func shelf() async throws {
        let old = ShelfItem(kind: .text(string: "old"))
        let invalid = ShelfItem(kind: .file(bookmark: Data()))
        let refreshed = ShelfItem(kind: .file(bookmark: Data([1])))
        let model = ShelfStateViewModel(items: [old, invalid, refreshed], persists: false)
        var entered = false
        var resume: CheckedContinuation<Void, Never>?
        let cleanup = Task { @MainActor in
            await model.cleanupInvalidItems { item in
                if item.id == old.id {
                    entered = true
                    await withCheckedContinuation { resume = $0 }
                }
                return item.id == old.id
            }
        }
        while !entered { await Task.yield() }
        model.remove(old)
        let added = ShelfItem(kind: .text(string: "added"))
        model.add([added])
        model.updateBookmark(for: refreshed, bookmark: Data([2]))
        resume?.resume()
        await cleanup.value
        check(model.items.map(\.id) == [refreshed.id, added.id], "Cleanup neither restores removed items nor erases insertions/refreshed bookmarks")

        func provider(_ text: String, delay: Double) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(Data(text.utf8), nil) }
                return nil
            }
            return provider
        }
        let result = await ShelfDropService.importItems(from: [provider("first", delay: 0.15), provider("second", delay: 0), NSItemProvider()])
        check(result.items.map(\.displayName) == ["first", "second"] && result.failedCount == 1,
              "Concurrent providers preserve order and report unsuccessful imports")
        let imports = ShelfStateViewModel(items: [], persists: false)
        imports.load([NSItemProvider()])
        while imports.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        check(imports.items.isEmpty && imports.importNotice?.contains("Couldn't import") == true,
              "A failed drop produces a visible error notice")
        imports.load([provider("batch one", delay: 0.1)])
        imports.load([provider("batch two", delay: 0)])
        while imports.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        check(imports.items.map(\.displayName) == ["batch one", "batch two"], "Overlapping drops preserve arrival order")
    }

    @MainActor static func socket() async throws {
        let data = Data("command\n".utf8)
        var bytes = Data()
        var calls = 0
        let partial = OctaveSocketWriter.writeAll(data, to: -1) { _, pointer, count in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            let count = min(2, count)
            bytes.append(pointer.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }
        check(partial == nil && bytes == data, "Partial writes and EINTR deliver the complete command")
        check(OctaveSocketWriter.writeAll(data, to: -1, write: { _, _, _ in errno = EPIPE; return -1 }) != nil,
              "Failed writes are reported")
        check(OctaveSocketWriter.writeAll(data, to: -1, write: { _, _, _ in 0 }) != nil, "Zero-byte writes fail without looping")

        let path = "/tmp/octave-check-" + UUID().uuidString + ".sock"
        let bridge = OctaveSocketBridge(path: path)
        let controller = OctaveController(bridge: bridge, reconnectGrace: .milliseconds(250))
        defer { bridge.stop() }
        func connect() throws -> Int32 {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { Darwin.close(descriptor); throw NSError(domain: "socket", code: Int(errno)) }
            return descriptor
        }
        func sendState(_ descriptor: Int32, title: String = "Song") {
            let json = Data("{\"type\":\"state\",\"title\":\"\(title)\",\"artist\":\"Artist\",\"position\":12,\"duration\":100,\"playing\":true}\n".utf8)
            check(OctaveSocketWriter.writeAll(json, to: descriptor) == nil, "Playback fixture reaches the real Unix socket")
        }
        var peer = try connect()
        sendState(peer)
        try await Task.sleep(for: .milliseconds(50))
        check(controller.playbackState.title == "Song", "Socket playback publishes metadata")
        Darwin.close(peer)
        try await Task.sleep(for: .milliseconds(60))
        check(controller.playbackState.title == "Song" && controller.isActive(), "A transport interruption retains playback during the grace period")
        peer = try connect()
        sendState(peer)
        try await Task.sleep(for: .milliseconds(300))
        check(controller.playbackState.title == "Song", "Fresh playback cancels disconnect expiry")
        let superseded = peer
        peer = try connect()
        sendState(peer, title: "Replacement")
        try await Task.sleep(for: .milliseconds(100))
        check(controller.playbackState.title == "Replacement", "A fresh host replaces a still-open old socket without waiting for EOF")
        Darwin.close(superseded)
        try await Task.sleep(for: .milliseconds(300))
        check(controller.playbackState.title == "Replacement" && bridge.isConnected,
              "Old-host disconnect callbacks cannot expire the replacement connection")
        check(OctaveSocketWriter.writeAll(Data("{\"type\":\"gone\"}\n".utf8), to: peer) == nil, "Explicit gone message reaches the socket")
        try await Task.sleep(for: .milliseconds(50))
        check(controller.playbackState.title.isEmpty, "Explicit nothing-playing clears immediately")
        sendState(peer)
        try await Task.sleep(for: .milliseconds(50))
        var disconnectReason: String?
        let controllerDisconnect = bridge.onDisconnect
        bridge.onDisconnect = { reason in
            disconnectReason = reason
            controllerDisconnect?(reason)
        }
        // A peer that stops consuming commands must hit the real send timeout.
        bridge.send(["type": "command", "padding": String(repeating: "x", count: 2_000_000)])
        let writeDeadline = Date().addingTimeInterval(6)
        while bridge.isConnected && Date() < writeDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        check(disconnectReason?.contains("command write failed") == true && !bridge.isConnected,
              "Actual broken socket writes report their reason and start playback grace")
        Darwin.close(peer)
        try await Task.sleep(for: .milliseconds(350))
        check(controller.playbackState.title.isEmpty && !controller.isActive(), "Sustained disconnect expires the retained playback")
        peer = try connect()
        sendState(peer)
        try await Task.sleep(for: .milliseconds(50))
        _ = OctaveSocketWriter.writeAll(Data(repeating: 120, count: 1_048_577), to: peer)
        let oversizedDeadline = Date().addingTimeInterval(2)
        while bridge.isConnected && Date() < oversizedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        check(disconnectReason?.contains("exceeded 1 MB") == true && !bridge.isConnected,
              "Oversized incoming frames close the client before unbounded parsing")
        Darwin.close(peer)
    }
}
