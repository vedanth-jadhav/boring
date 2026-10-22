import Combine
import Defaults
import Foundation

@MainActor
final class EnhancedLyricsSettingsModel: ObservableObject {
    @Published var draftKey = ""
    @Published private(set) var hasSavedKey = false
    @Published private(set) var needsKeychainAccess = false
    @Published private(set) var storageUnavailable = false
    @Published private(set) var isBusy = false
    @Published private(set) var progressText = "Checking API key…"
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    private var operation: Task<Void, Never>?
    private var statusGeneration = 0

    var canSave: Bool { !isBusy && !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func loadStatus() async {
        guard !isBusy else { return }
        statusGeneration += 1
        let generation = statusGeneration
        let status = await Task.detached(priority: .utility) { SpicyLyricsCredential.savedStatus() }.value
        guard !Task.isCancelled, generation == statusGeneration, !isBusy else { return }
        if status != .unavailable { hasSavedKey = status != .missing }
        needsKeychainAccess = status == .needsAccess
        storageUnavailable = status == .unavailable
        if status == .unavailable {
            report("Keychain is temporarily unavailable. Unlock it and try again; the saved key has not been changed.", error: true)
        } else if status == .needsAccess {
            report("Your saved key needs a one-time move to secure storage that survives app updates. Authorize it below; enter your login password if macOS asks.", error: true)
        } else {
            clearMessage()
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
        statusGeneration += 1
        progressText = "Saving API key…"
        message = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                try await Task.detached(priority: .utility) { try SpicyLyricsCredential.save(key) }.value
                await SpicyLyricsClient.shared.reloadCredential(credential: key)
                self.hasSavedKey = true
                self.needsKeychainAccess = false
                self.storageUnavailable = false
                self.draftKey = ""
                Defaults[.enableEnhancedLyrics] = true
                Defaults[.enableLyrics] = true
                LyricsService.shared.configurationChanged(reloadCredential: false)
                self.report("Key saved and verified in Keychain. Enhanced lyrics are on.", error: false)
            } catch { self.reportStorageError(error) }
        }
    }

    func checkSavedKey() {
        guard !isBusy else { return }
        isBusy = true
        statusGeneration += 1
        progressText = "Checking API key…"
        message = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            let result = await Task.detached(priority: .utility) { SpicyLyricsCredential.loadResult() }.value
            guard case .loaded(let key) = result else {
                if case .inaccessible(let status) = result {
                    self.needsKeychainAccess = SpicyLyricsCredential.requiresAuthorization(status)
                    self.storageUnavailable = !self.needsKeychainAccess
                    self.report(self.needsKeychainAccess ? "Authorize your saved key to check it." : "Couldn't read Keychain. Unlock it and retry storage.", error: true)
                } else {
                    self.hasSavedKey = false
                    self.report("Add an API key before checking it.", error: true)
                }
                return
            }
            switch await SpicyLyricsClient.shared.validateCredential(key) {
            case .valid: self.report("Spicy Lyrics accepted your saved key.", error: false)
            case .invalid: self.report("Spicy Lyrics rejected your saved key. Paste a replacement key.", error: true)
            case .restricted: self.report("Your key is saved, but doesn't allow desktop requests. Update its permissions in the Spicy Lyrics dashboard.", error: true)
            case .rateLimited: self.report("Your key is saved. Spicy Lyrics is limiting requests; try checking again later.", error: false)
            case .unavailable: self.report("Your key is saved. Couldn't reach Spicy Lyrics; check your connection and try again.", error: false)
            }
        }
    }

    func removeKey() {
        guard !isBusy else { return }
        isBusy = true
        statusGeneration += 1
        progressText = "Removing API key…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                try await Task.detached(priority: .utility) { try SpicyLyricsCredential.remove() }.value
                await SpicyLyricsClient.shared.reloadCredential()
                Defaults[.enableEnhancedLyrics] = false
                LyricsService.shared.configurationChanged(reloadCredential: false)
                self.hasSavedKey = false
                self.needsKeychainAccess = false
                self.storageUnavailable = false
                self.draftKey = ""
                self.report("Key removed. Regular lyrics are active.", error: false)
            } catch { self.reportStorageError(error) }
        }
    }

    func authorizeSavedKey() {
        guard !isBusy else { return }
        isBusy = true
        statusGeneration += 1
        progressText = "Authorizing saved key…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let key = try await Task.detached(priority: .utility) { try SpicyLyricsCredential.authorizeSavedKey() }.value
                await SpicyLyricsClient.shared.reloadCredential(credential: key)
                self.needsKeychainAccess = false
                self.storageUnavailable = false
                self.hasSavedKey = true
                LyricsService.shared.configurationChanged(reloadCredential: false)
                self.report("Saved key authorized. App rebuilds keep this access.", error: false)
            } catch { self.reportStorageError(error) }
        }
    }

    func clearMessage() { message = nil; isError = false }

    func cancelEditing() {
        // Keychain writes cannot be canceled once sent; finish updating state after closing settings.
        draftKey = ""
    }

    private func report(_ text: String, error: Bool) {
        message = text
        isError = error
    }

    private func reportStorageError(_ error: Error) {
        if let storageError = error as? SpicyLyricsCredential.StorageError,
           case .status(let status) = storageError, SpicyLyricsCredential.requiresAuthorization(status) {
            needsKeychainAccess = true
            hasSavedKey = true
        }
        report(error.localizedDescription, error: true)
    }

    deinit { operation?.cancel() }
}
