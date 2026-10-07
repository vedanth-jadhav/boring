import Combine
import Defaults
import Foundation

@MainActor
final class EnhancedLyricsSettingsModel: ObservableObject {
    @Published var draftKey = ""
    @Published private(set) var hasSavedKey = false
    @Published private(set) var needsKeychainAccess = false
    @Published private(set) var isBusy = false
    @Published private(set) var progressText = "Checking API key…"
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    private var operation: Task<Void, Never>?

    var canSave: Bool { !isBusy && !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func loadStatus() async {
        let status = await Task.detached(priority: .utility) { SpicyLyricsCredential.savedStatus() }.value
        guard !Task.isCancelled else { return }
        hasSavedKey = status != .missing
        needsKeychainAccess = status == .needsAccess
        if status == .needsAccess {
            report("Your key is still saved in Keychain. Authorize it once below to restore enhanced lyrics. The app won’t request access automatically on launch.", error: true)
        }
    }

    func saveAndEnable() {
        guard !isBusy else { return }
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SpicyLyricsCredential.accepts(key) else {
            report("Paste a Spicy Lyrics key beginning with sl_sk_ or sl_pk_.", error: true)
            return
        }
        isBusy = true
        progressText = "Checking API key…"
        message = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            let validation = await SpicyLyricsClient.shared.validateCredential(key)
            guard !Task.isCancelled else { return }
            switch validation {
            case .valid:
                do {
                    try await Task.detached(priority: .utility) { try SpicyLyricsCredential.save(key) }.value
                    await SpicyLyricsClient.shared.reloadCredential()
                    self.hasSavedKey = true
                    self.needsKeychainAccess = false
                    self.draftKey = ""
                    Defaults[.enableEnhancedLyrics] = true
                    Defaults[.enableLyrics] = true
                    LyricsService.shared.configurationChanged()
                    self.report("Key saved. Enhanced lyrics are on.", error: false)
                } catch { self.report(error.localizedDescription, error: true) }
            case .invalid:
                self.report("Spicy Lyrics didn't accept this key. Copy a key from your own application and try again.", error: true)
            case .restricted:
                self.report("This key doesn't allow desktop requests. Use your own secret key, or allow requests without an origin for your client key in the dashboard.", error: true)
            case .rateLimited:
                self.report("Spicy Lyrics is limiting requests. Wait a minute, then try again.", error: true)
            case .unavailable:
                self.report("Couldn't reach Spicy Lyrics. Check your connection and try again.", error: true)
            }
        }
    }

    func removeKey() {
        guard !isBusy else { return }
        isBusy = true
        progressText = "Removing API key…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                try await Task.detached(priority: .utility) { try SpicyLyricsCredential.remove() }.value
                await SpicyLyricsClient.shared.reloadCredential()
                Defaults[.enableEnhancedLyrics] = false
                LyricsService.shared.configurationChanged()
                self.hasSavedKey = false
                self.needsKeychainAccess = false
                self.draftKey = ""
                self.report("Key removed. Regular lyrics are active.", error: false)
            } catch { self.report(error.localizedDescription, error: true) }
        }
    }

    func authorizeSavedKey() {
        guard !isBusy else { return }
        isBusy = true
        progressText = "Authorizing saved key…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                try await Task.detached(priority: .utility) { try SpicyLyricsCredential.authorizeSavedKey() }.value
                await SpicyLyricsClient.shared.reloadCredential()
                self.needsKeychainAccess = false
                self.hasSavedKey = true
                LyricsService.shared.configurationChanged()
                self.report("Saved key authorized for this signed app.", error: false)
            } catch { self.report(error.localizedDescription, error: true) }
        }
    }

    func clearMessage() { message = nil; isError = false }

    func cancelEditing() {
        operation?.cancel()
        draftKey = ""
    }

    private func report(_ text: String, error: Bool) {
        message = text
        isError = error
    }

    deinit { operation?.cancel() }
}
