import Combine
import Defaults
import Foundation
import Security

// Only external storage/network/lyrics dependencies are replaced; the settings model is production.
extension Defaults.Keys {
    static let enableLyrics = Key<Bool>("lyricsChecks.enabled", default: false)
    static let enableEnhancedLyrics = Key<Bool>("lyricsChecks.enhanced", default: false)
}
enum SpicyLyricsCredential {
    enum SavedStatus { case available, missing, needsAccess, unavailable }
    enum LoadResult { case loaded(String), missing, inaccessible(OSStatus) }
    enum Failure: Error { case unavailable }
    enum StorageError: Error { case status(OSStatus) }
    static let lock = NSLock()
    static var key: String?
    static var failWrites = false
    static var statusStarted: DispatchSemaphore?
    static var statusRelease: DispatchSemaphore?
    static var saveStarted: DispatchSemaphore?
    static var saveRelease: DispatchSemaphore?
    static func accepts(_ value: String) -> Bool { value.hasPrefix("sl_sk_") && value.count >= 20 }
    static func requiresAuthorization(_ status: OSStatus) -> Bool { status == errSecAuthFailed }
    static func savedStatus() -> SavedStatus {
        lock.lock()
        let snapshot: SavedStatus = key == nil ? .missing : .available
        let started = statusStarted, release = statusRelease
        lock.unlock()
        started?.signal()
        release?.wait()
        return snapshot
    }
    static func loadResult() -> LoadResult {
        lock.lock(); defer { lock.unlock() }
        return key.map(LoadResult.loaded) ?? .missing
    }
    static func save(_ value: String) throws {
        saveStarted?.signal()
        saveRelease?.wait()
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw Failure.unavailable }
        key = value
    }
    static func remove() throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw Failure.unavailable }
        key = nil
    }
    static func authorizeSavedKey() throws -> String { throw Failure.unavailable }
}
actor SpicyLyricsClient {
    static let shared = SpicyLyricsClient()
    enum KeyValidation { case valid, invalid, restricted, rateLimited, unavailable }
    var validation: KeyValidation = .unavailable
    var validationCalls = 0
    func credentialForRequest() -> String? { SpicyLyricsCredential.key }
    func reloadCredential(credential: String? = nil) {}
    func setValidation(_ value: KeyValidation) { validation = value }
    func validateCredential(_ key: String) -> KeyValidation { validationCalls += 1; return validation }
}
@MainActor final class LyricsService {
    static let shared = LyricsService()
    func configurationChanged(reloadCredential: Bool) {}
}

@main struct LyricsSettingsChecks {
    static func waitForFixture(_ signal: DispatchSemaphore) {
        precondition(signal.wait(timeout: .now() + 5) == .success, "Fixture did not start")
    }
    @MainActor static func settled(_ model: EnhancedLyricsSettingsModel) async throws {
        for _ in 0..<500 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Settings operation did not finish")
    }
    @MainActor static func main() async throws {
        defer { Defaults.reset(.enableLyrics, .enableEnhancedLyrics) }
        Defaults[.enableLyrics] = false
        Defaults[.enableEnhancedLyrics] = false
        let model = EnhancedLyricsSettingsModel()
        let key = "sl_sk_offline_fixture_1234567890"
        model.draftKey = key
        model.saveAndEnable()
        try await settled(model)
        let validationCalls = await SpicyLyricsClient.shared.validationCalls
        precondition(model.hasSavedKey && SpicyLyricsCredential.key == key && validationCalls == 0)
        precondition(Defaults[.enableLyrics] && Defaults[.enableEnhancedLyrics])
        print("PASS: offline save persists and enables lyrics without contacting the provider")

        model.checkSavedKey()
        try await settled(model)
        precondition(!model.isError && model.hasSavedKey && SpicyLyricsCredential.key == key)
        precondition(model.message?.contains("Couldn't reach") == true)
        await SpicyLyricsClient.shared.setValidation(.invalid)
        model.checkSavedKey()
        try await settled(model)
        precondition(model.isError && model.hasSavedKey && SpicyLyricsCredential.key == key)
        print("PASS: provider outage and rejected key never erase saved credentials")

        model.draftKey = "bad"
        model.saveAndEnable()
        precondition(!model.isBusy && model.isError && SpicyLyricsCredential.key == key)
        SpicyLyricsCredential.failWrites = true
        model.draftKey = "sl_sk_replacement_fixture_1234567890"
        model.saveAndEnable()
        try await settled(model)
        precondition(model.isError && model.draftKey.hasPrefix("sl_sk_replacement") && SpicyLyricsCredential.key == key)
        model.removeKey()
        try await settled(model)
        precondition(model.isError && model.hasSavedKey && Defaults[.enableEnhancedLyrics])
        SpicyLyricsCredential.failWrites = false
        print("PASS: failed saves/removals retain the key, draft and enabled state")

        SpicyLyricsCredential.key = nil
        SpicyLyricsCredential.statusStarted = DispatchSemaphore(value: 0)
        SpicyLyricsCredential.statusRelease = DispatchSemaphore(value: 0)
        let loading = Task { await model.loadStatus() }
        let started = SpicyLyricsCredential.statusStarted!
        await Task.detached { waitForFixture(started) }.value
        model.draftKey = key
        model.saveAndEnable()
        try await settled(model)
        SpicyLyricsCredential.statusRelease!.signal()
        await loading.value
        SpicyLyricsCredential.statusStarted = nil
        SpicyLyricsCredential.statusRelease = nil
        precondition(model.hasSavedKey && model.message?.contains("saved and verified") == true)
        print("PASS: stale opening status cannot overwrite a completed save")

        SpicyLyricsCredential.saveStarted = DispatchSemaphore(value: 0)
        SpicyLyricsCredential.saveRelease = DispatchSemaphore(value: 0)
        model.draftKey = "sl_sk_closing_fixture_1234567890"
        model.saveAndEnable()
        let writing = SpicyLyricsCredential.saveStarted!
        await Task.detached { waitForFixture(writing) }.value
        model.cancelEditing()
        SpicyLyricsCredential.saveRelease!.signal()
        try await settled(model)
        SpicyLyricsCredential.saveStarted = nil
        SpicyLyricsCredential.saveRelease = nil
        precondition(model.hasSavedKey && SpicyLyricsCredential.key == "sl_sk_closing_fixture_1234567890")
        precondition(Defaults[.enableEnhancedLyrics])
        model.removeKey()
        try await settled(model)
        precondition(!model.hasSavedKey && SpicyLyricsCredential.key == nil && !Defaults[.enableEnhancedLyrics])
        print("PASS: closing settings during storage completes the commit; successful removal disables enhancement")
    }
}
