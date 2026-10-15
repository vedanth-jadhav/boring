import Foundation
import Security

/// A separate, unchanged executable keeps the login Keychain partition stable across app builds.
enum LyricsKeychainClient {
    static func perform(_ operation: String, value: String? = nil) -> SpicyLyricsCredential.LoadResult {
        let connection = NSXPCConnection(serviceName: "local.vedanth.boringnotch.octave.LyricsKeychain")
        connection.remoteObjectInterface = NSXPCInterface(with: LyricsKeychainProtocol.self)
        let resultLock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        var result: SpicyLyricsCredential.LoadResult = .inaccessible(errSecNotAvailable)
        var completed = false
        func finish(_ outcome: SpicyLyricsCredential.LoadResult) {
            resultLock.lock()
            defer { resultLock.unlock() }
            guard !completed else { return }
            completed = true
            result = outcome
            finished.signal()
        }
        connection.interruptionHandler = { finish(.inaccessible(errSecNotAvailable)) }
        connection.invalidationHandler = { finish(.inaccessible(errSecNotAvailable)) }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            finish(.inaccessible(errSecNotAvailable))
        }) as? LyricsKeychainProtocol else { return .inaccessible(errSecNotAvailable) }
        proxy.perform(operation, value: value) { key, status in
            if status == errSecSuccess { finish(.loaded(key ?? "")) }
            else if status == errSecItemNotFound { finish(.missing) }
            else { finish(.inaccessible(status)) }
        }
        // Interactive requests must allow time for the user's Keychain password dialog.
        let timeout: DispatchTime = .now() + (operation == "load" ? 10 : 300)
        guard finished.wait(timeout: timeout) == .success else { return .inaccessible(errSecNotAvailable) }
        resultLock.lock()
        defer { resultLock.unlock() }
        return result
    }
}
