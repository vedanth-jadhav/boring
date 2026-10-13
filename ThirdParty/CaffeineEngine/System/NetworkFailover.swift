import Foundation
import Network
import Security

// MARK: - Pure state machine (spec section 7)

/// Drives hotspot failover from three events. No clocks, no timers, no I/O:
/// the driver owns those and feeds `Date`s in.
struct FailoverMachine: Sendable, Equatable {
    enum Output: Sendable, Equatable {
        case joinHotspot
        case scheduleRetry(after: TimeInterval)
        case recovered(start: Date, gap: TimeInterval)
    }

    /// Seconds the path must stay unsatisfied before the first join.
    static let initialDelay: TimeInterval = 5
    /// Delays after each join attempt: 5, 10, 20, 30, 30, 30, ...
    static let backoff: [TimeInterval] = [5, 10, 20, 30]

    private(set) var outageStart: Date?
    private(set) var joins: Int = 0
    private(set) var nextAttemptAt: Date?

    var inOutage: Bool { outageStart != nil }

    static func delay(afterJoin n: Int) -> TimeInterval {
        backoff[min(max(n - 1, 0), backoff.count - 1)]
    }

    mutating func pathUnsatisfied(at now: Date) -> [Output] {
        guard outageStart == nil else { return [] }
        outageStart = now
        joins = 0
        nextAttemptAt = now.addingTimeInterval(Self.initialDelay)
        return [.scheduleRetry(after: Self.initialDelay)]
    }

    mutating func pathSatisfied(at now: Date) -> [Output] {
        guard let start = outageStart else { return [] }
        outageStart = nil
        joins = 0
        nextAttemptAt = nil
        return [.recovered(start: start, gap: max(0, now.timeIntervalSince(start)))]
    }

    mutating func timerFired(at now: Date) -> [Output] {
        guard outageStart != nil, let due = nextAttemptAt, now >= due else { return [] }
        joins += 1
        let delay = Self.delay(afterJoin: joins)
        nextAttemptAt = now.addingTimeInterval(delay)
        return [.joinHotspot, .scheduleRetry(after: delay)]
    }

    /// One handoffs.log line per outage.
    static func logLine(start: Date, end: Date, gap: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        return "\(f.string(from: end)) outage start=\(f.string(from: start)) end=\(f.string(from: end)) gap=\(Int(gap.rounded()))s"
    }

    /// "2m 10s", "45s", "1h 2m 3s".
    static func humanGap(_ gap: TimeInterval) -> String {
        let total = Int(gap.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 || parts.isEmpty { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }
}

// MARK: - networksetup parsing

enum HardwarePortsParser {
    /// Device name of the Wi-Fi port in `networksetup -listallhardwareports`
    /// output, e.g. "en0".
    static func wifiInterface(from output: String) -> String? {
        var currentIsWifi = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let name = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
                currentIsWifi = name == "Wi-Fi" || name == "AirPort" || name.lowercased().contains("wi-fi")
            } else if line.hasPrefix("Device:"), currentIsWifi {
                let dev = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty { return dev }
            }
        }
        return nil
    }

    /// SSID from `networksetup -getairportnetwork en0`
    /// ("Current Wi-Fi Network: Foo"), nil when not associated.
    static func ssid(fromGetAirportNetwork output: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = line.range(of: "Current Wi-Fi Network:") else { return nil }
        let ssid = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return ssid.isEmpty ? nil : ssid
    }
}

// MARK: - Keychain

/// Synchronous: a call can wait on a keychain dialog for as long as the
/// user leaves it open. The app makes these calls only on `KeychainQueue`.
protocol KeychainStoring: Sendable {
    func get(service: String, account: String) throws -> String?
    func set(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

/// Runs the app's keychain calls one at a time on a thread of their own.
/// A save can wait on a keychain dialog until the user answers it; on the
/// main actor that wait would hold up the battery floor, the deadline
/// timer and End. The prompt switch is process-wide, so a read that turns
/// prompts off must not run while a save has them on: one serial queue
/// for every call keeps them apart. A dispatch queue rather than an
/// actor, so a call left waiting on a dialog holds this queue's thread
/// and not one of the shared pool's.
final class KeychainQueue: Sendable {
    /// The one the app uses, for the failover's reads and Settings' saves.
    static let shared = KeychainQueue()

    private let queue = DispatchQueue(label: "com.kgarg.boring-caffeine.keychain")

    init() {}

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

struct KeychainError: Error, LocalizedError, Sendable {
    let status: OSStatus
    var errorDescription: String? {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "keychain: \(msg)"
    }

    /// The item is there but macOS would have to show a keychain prompt to
    /// hand it over, and none was allowed. Measured on a throwaway keychain:
    /// an item whose access list names another build (errSecAuthFailed), a
    /// locked keychain (errSecAuthFailed too), and a delete of another
    /// build's item (errSecInvalidOwnerEdit).
    var isUnreadableWithoutPrompt: Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed || status == errSecInvalidOwnerEdit
    }

    var problem: HotspotPasswordProblem {
        isUnreadableWithoutPrompt ? .unreadable : .error(errorDescription ?? "OSStatus \(status)")
    }
}

/// The configured hotspot SSID as the keychain account: what the failover
/// joins and Settings saves under. One rule for both, so a check that the
/// SSID is still the same after a keychain wait compares like with like.
enum HotspotSSID {
    static func normalized(_ configured: String) -> String {
        configured.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why the failover has no hotspot password to join with. Shown in the
/// menu, in Settings and in one notification per outage; the join is never
/// skipped without one of these being surfaced.
enum HotspotPasswordProblem: Equatable, Sendable {
    /// No keychain item for the configured SSID.
    case missing
    /// The item exists but this build of Caffeine may not read it without a
    /// keychain prompt: it was saved by another build (an ad-hoc signature
    /// changes on every install), or the login keychain is locked.
    case unreadable
    /// Any other keychain failure.
    case error(String)

    /// One sentence for the notification body and the Settings notice.
    var explanation: String {
        switch self {
        case .missing:
            "No hotspot password is saved. Enter it in Settings."
        case .unreadable:
            "This build of Caffeine can't read the saved hotspot password (it was saved by another build, or the login keychain is locked). Enter it again in Settings."
        case let .error(message):
            "The hotspot password can't be read: \(message)"
        }
    }

    /// The right-click menu's warning line.
    var menuLine: String {
        switch self {
        case .missing:
            "\u{26A0} Hotspot password not saved: enter it in Settings"
        case .unreadable:
            "\u{26A0} Hotspot password unreadable by this build: enter it again in Settings"
        case let .error(message):
            "\u{26A0} Hotspot password unreadable: \(message)"
        }
    }

    /// Under the password field in Settings. A missing item needs no notice
    /// there: the field is empty.
    var settingsNotice: String? {
        switch self {
        case .missing:
            nil
        case .unreadable:
            "This build of Caffeine can't read the saved password: it was saved by another build, or the login keychain is locked. Enter it again and save. macOS may ask you to allow Caffeine to replace the old item."
        case let .error(message):
            "The saved password can't be read: \(message)"
        }
    }
}

/// A problem the failover reported, with the hotspot SSID it read for.
/// The menu and Settings show it only while that hotspot is the one
/// configured: after an SSID edit it is about an item no join reads.
struct HotspotPasswordReport: Equatable, Sendable {
    let ssid: String
    let problem: HotspotPasswordProblem

    /// The problem, if this report is about `configuredSSID`.
    func problem(for configuredSSID: String) -> HotspotPasswordProblem? {
        ssid == HotspotSSID.normalized(configuredSSID) ? problem : nil
    }

    /// Whether the report still stands after a save or clear in Settings
    /// made `change`. A report about either item the save wrote or removed
    /// is out of date. The one report that stands is about the hotspot
    /// configured now, when the save touched neither of its items: it
    /// stored for an SSID edited away while it waited, and the window had
    /// not loaded the configured one.
    func stands(after change: HotspotPasswordChange, configuredSSID: String) -> Bool {
        let configured = HotspotSSID.normalized(configuredSSID)
        return ssid == configured && !change.touches(configured)
    }
}

/// The keychain items a save or clear in Settings changed: the one it
/// stored or cleared for `ssid`, read when it began, and the one it
/// removed for `removed`, the SSID the window had loaded, when the SSID
/// was edited since the load.
struct HotspotPasswordChange: Equatable, Sendable {
    let ssid: String
    let removed: String?

    init(ssid: String, removed: String? = nil) {
        self.ssid = ssid
        self.removed = removed
    }

    /// Whether the save wrote or removed the item for `ssid`.
    func touches(_ ssid: String) -> Bool {
        ssid == self.ssid || ssid == removed
    }
}

/// The file-based keychain calls this store needs that the SDK marks
/// deprecated since macOS 10.10 but still ships: the process-wide prompt
/// switch, the per-item access list and the keychain an item lives in.
/// Resolved by name, like the DisplayServices calls, so the build stays
/// warning-free. They are public exports of Security.framework.
enum LegacyKeychain {
    private typealias SetInteraction = @convention(c) (UInt8) -> OSStatus
    private typealias GetInteraction = @convention(c) (UnsafeMutablePointer<UInt8>) -> OSStatus
    private typealias AccessCreate = @convention(c) (CFString, CFArray?, UnsafeMutablePointer<Unmanaged<SecAccess>?>) -> OSStatus
    private typealias ItemCopyKeychain = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Unmanaged<SecKeychain>?>) -> OSStatus
    private typealias TrustedApplicationCreate = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Unmanaged<SecTrustedApplication>?>) -> OSStatus
    private typealias GetStatus = @convention(c) (SecKeychain?, UnsafeMutablePointer<UInt32>) -> OSStatus
    private typealias Unlock = @convention(c) (SecKeychain?, UInt32, UnsafeRawPointer?, UInt8) -> OSStatus

    private static func symbol<T>(_ name: String) throws -> T {
        guard let handle = dlopen(nil, RTLD_LAZY), let pointer = dlsym(handle, name) else {
            throw KeychainError(status: errSecUnimplemented)
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The read and the write behind the process-wide prompt switch, as a
    /// seam: the app uses Security's pair, tests pass ones that fail or
    /// record.
    struct PromptSwitch: Sendable {
        /// The call's status and the current setting.
        let read: @Sendable () -> (OSStatus, Bool)
        let write: @Sendable (Bool) -> OSStatus

        static func system() throws -> PromptSwitch {
            let set: SetInteraction = try symbol("SecKeychainSetUserInteractionAllowed")
            let get: GetInteraction = try symbol("SecKeychainGetUserInteractionAllowed")
            return PromptSwitch(
                read: {
                    var state: UInt8 = 1
                    let status = get(&state)
                    return (status, state != 0)
                },
                write: { set($0 ? 1 : 0) }
            )
        }
    }

    /// Runs `body` with keychain prompts allowed or forbidden for this
    /// process and puts the previous setting back. With prompts forbidden an
    /// operation that would need one fails instead (see
    /// `KeychainError.isUnreadableWithoutPrompt`). Per-query keys such as
    /// kSecUseAuthenticationUI only govern the data protection keychain;
    /// this switch is what the file-based login keychain honours. A switch
    /// that cannot be read or written stops the call before `body` runs:
    /// an unknown setting could mean a prompt during an outage.
    static func withPrompts<T>(_ allowed: Bool, using prompts: PromptSwitch? = nil, _ body: () throws -> T) throws -> T {
        let prompts = try prompts ?? PromptSwitch.system()
        let (readStatus, previous) = prompts.read()
        guard readStatus == errSecSuccess else { throw KeychainError(status: readStatus) }
        let writeStatus = prompts.write(allowed)
        guard writeStatus == errSecSuccess else { throw KeychainError(status: writeStatus) }
        defer {
            let restored = prompts.write(previous)
            if restored != errSecSuccess {
                Log.error("keychain prompt switch not put back: OSStatus \(restored)")
            }
        }
        return try body()
    }

    /// Whether this process may currently raise keychain prompts.
    static func promptsAllowed() throws -> Bool {
        let (status, allowed) = try PromptSwitch.system().read()
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return allowed
    }

    /// The keychain file an item lives in.
    static func keychain(of item: CFTypeRef) throws -> SecKeychain {
        let copy: ItemCopyKeychain = try symbol("SecKeychainItemCopyKeychain")
        var keychain: Unmanaged<SecKeychain>?
        let status = copy(Unmanaged.passUnretained(item).toOpaque(), &keychain)
        guard status == errSecSuccess, let keychain else { throw KeychainError(status: status) }
        return keychain.takeRetainedValue()
    }

    /// Whether `keychain` (nil: the default keychain) is locked. Only reads
    /// its status, so no prompt.
    static func isLocked(_ keychain: SecKeychain?) throws -> Bool {
        let get: GetStatus = try symbol("SecKeychainGetStatus")
        var status: UInt32 = 0
        let result = get(keychain, &status)
        guard result == errSecSuccess else { throw KeychainError(status: result) }
        // kSecUnlockStateStatus
        return status & 1 == 0
    }

    /// Unlocks `keychain` (nil: the default keychain) by asking the user for
    /// its password, if prompts are allowed; otherwise it fails.
    static func unlock(_ keychain: SecKeychain?) throws {
        let unlock: Unlock = try symbol("SecKeychainUnlock")
        let result = unlock(keychain, 0, nil, 0)
        guard result == errSecSuccess else { throw KeychainError(status: result) }
    }

    /// This process's code as a trusted application. Under ad-hoc signing
    /// its designated requirement is the build's cdhash, so an access list
    /// naming it trusts exactly this build.
    static func thisApplication() throws -> SecTrustedApplication {
        let create: TrustedApplicationCreate = try symbol("SecTrustedApplicationCreateFromPath")
        var application: Unmanaged<SecTrustedApplication>?
        let status = create(nil, &application)
        guard status == errSecSuccess, let application else { throw KeychainError(status: status) }
        return application.takeRetainedValue()
    }

    /// An access list that lets `applications` use the item without a
    /// prompt and makes everyone else ask. `descriptor` is what that prompt
    /// names. An empty list trusts nobody.
    static func access(descriptor: String, trusting applications: [SecTrustedApplication]) throws -> SecAccess {
        let create: AccessCreate = try symbol("SecAccessCreate")
        var access: Unmanaged<SecAccess>?
        let status = create(descriptor as CFString, applications as CFArray, &access)
        guard status == errSecSuccess, let access else { throw KeychainError(status: status) }
        return access.takeRetainedValue()
    }
}

/// The SecItem calls behind `KeychainStore`, plus the lookup of the
/// keychain file an item lives in, as a seam. The app uses Security's;
/// tests script the status codes and record the call order and the prompt
/// switch at each call, which covers the paths that need a prompt in real
/// life (another build's item, a locked keychain) without raising one.
protocol KeychainItemCalls: Sendable {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
    /// The keychain file holding `item`, a reference from `copyMatching`.
    func keychain(of item: CFTypeRef) -> (OSStatus, SecKeychain?)
    /// Whether that keychain is locked.
    func isLocked(_ keychain: SecKeychain?) -> (OSStatus, Bool)
    /// Unlocks it, with the system's password prompt when prompts are
    /// allowed.
    func unlock(_ keychain: SecKeychain?) -> OSStatus
}

struct SecurityItemCalls: KeychainItemCalls {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }

    func keychain(of item: CFTypeRef) -> (OSStatus, SecKeychain?) {
        do {
            return (errSecSuccess, try LegacyKeychain.keychain(of: item))
        } catch let error as KeychainError {
            return (error.status, nil)
        } catch {
            return (errSecUnimplemented, nil)
        }
    }

    func isLocked(_ keychain: SecKeychain?) -> (OSStatus, Bool) {
        do {
            return (errSecSuccess, try LegacyKeychain.isLocked(keychain))
        } catch let error as KeychainError {
            return (error.status, false)
        } catch {
            return (errSecUnimplemented, false)
        }
    }

    func unlock(_ keychain: SecKeychain?) -> OSStatus {
        do {
            try LegacyKeychain.unlock(keychain)
            return errSecSuccess
        } catch let error as KeychainError {
            return error.status
        } catch {
            return errSecUnimplemented
        }
    }
}

/// Login keychain generic password, service `boring-caffeine-hotspot`, account =
/// SSID. The item's access list names only the Caffeine build that saved it
/// (`LegacyKeychain.thisApplication()`), and every read runs with keychain
/// prompts forbidden, so the failover never raises a dialog: an item this
/// build may not open fails with `KeychainError.isUnreadableWithoutPrompt`
/// and the caller surfaces `HotspotPasswordProblem.unreadable`.
///
/// A save writes to the keychain file that holds the item reads find,
/// which need not be the default keychain. A locked keychain hides this
/// build's items as well as another build's, so a save that finds the
/// item unreadable first unlocks that keychain and starts over. An item
/// this build can read already names this build in its access list, so
/// only its value changes, in place. An item it still cannot read is
/// another build's and needs a new access list, which the file-based
/// keychain changes only by replacing the item: the new password goes
/// beside it under `replacementService(for:)`, the old item is deleted,
/// and the new one is renamed into its place. `get` reads only the item
/// itself, never a replacement, so it cannot return a password some other
/// save left under that name, in this keychain or another one on the
/// search list. The cost is one rare state: a save stopped between the
/// delete and the rename leaves the new password where reads do not look,
/// the password reads as missing, and the user enters it again; that save
/// then finishes the swap. The prompts a save may raise, the unlock and
/// the delete of another build's item, are allowed because a save or clear
/// is the user's own click in Settings. Every call can wait on such a
/// prompt, so the app runs them on `KeychainQueue`.
///
/// `kSecAttrAccessible` (this device only, when unlocked) is not set: the
/// file-based login keychain accepts and drops it (measured on a throwaway
/// keychain, the attribute does not read back), and the data protection
/// keychain that honours it needs a keychain access group entitlement,
/// which needs a team id.
struct KeychainStore: KeychainStoring, @unchecked Sendable {
    static let service = "boring-caffeine-hotspot"
    /// What the keychain prompt names if another program asks for the item.
    static let accessDescriptor = "Caffeine hotspot password"

    /// Where a save keeps the new password while it replaces an item this
    /// build cannot read.
    static func replacementService(for service: String) -> String {
        "\(service).replacing"
    }

    /// The keychains searched, in order; nil is the user's search list.
    /// Tests pass throwaway keychain files; the app passes nothing. CF
    /// references the store never mutates, hence the unchecked Sendable.
    private let searchList: [SecKeychain]?
    /// Where an item with no existing copy is added; nil is the default
    /// keychain.
    private let newItems: SecKeychain?
    private let calls: any KeychainItemCalls
    /// nil is Security's process-wide switch. Tests against a throwaway
    /// keychain pass one that refuses to allow prompts.
    private let prompts: LegacyKeychain.PromptSwitch?

    init(
        keychain: SecKeychain? = nil,
        calls: any KeychainItemCalls = SecurityItemCalls(),
        prompts: LegacyKeychain.PromptSwitch? = nil
    ) {
        self.init(searchList: keychain.map { [$0] }, newItems: keychain, calls: calls, prompts: prompts)
    }

    init(
        searchList: [SecKeychain]?,
        newItems: SecKeychain?,
        calls: any KeychainItemCalls = SecurityItemCalls(),
        prompts: LegacyKeychain.PromptSwitch? = nil
    ) {
        self.searchList = searchList
        self.newItems = newItems
        self.calls = calls
        self.prompts = prompts
    }

    /// The item itself only. A replacement is never read: which save left
    /// it, and whether that save finished, is not known.
    func get(service: String, account: String) throws -> String? {
        let (status, data) = try read(service: service, account: account)
        if status == errSecSuccess { return data.map { String(decoding: $0, as: UTF8.self) } }
        if status == errSecItemNotFound { return nil }
        throw KeychainError(status: status)
    }

    func set(service: String, account: String, value: String) throws {
        try set(service: service, account: account, data: Data(value.utf8), unlocked: false)
    }

    /// `unlocked`: this save has already unlocked the keychain once.
    private func set(service: String, account: String, data: Data, unlocked: Bool) throws {
        let (status, _) = try read(service: service, account: account)
        switch status {
        case errSecItemNotFound:
            try add(service: service, account: account, data: data, label: service, to: newItems)
        case errSecSuccess:
            // Readable without a prompt, so the access list already names
            // this build: one in-place change of the value.
            let holder = try keychainHolding(service: service, account: account)
            try updateValue(service: service, account: account, data: data, in: holder)
        default:
            guard KeychainError(status: status).isUnreadableWithoutPrompt else { throw KeychainError(status: status) }
            let holder = try keychainHolding(service: service, account: account)
            if try isLocked(holder) {
                // Locked, every item reads as unreadable, this build's own
                // included. Unlock (the user's Save allows the prompt) and
                // decide again by what reads return then.
                guard !unlocked else { throw KeychainError(status: errSecInteractionNotAllowed) }
                let result = try withPrompts(true) { calls.unlock(holder) }
                guard result == errSecSuccess else { throw KeychainError(status: result) }
                try set(service: service, account: account, data: data, unlocked: true)
                return
            }
            try replaceUnreadable(service: service, account: account, data: data, in: holder)
            return
        }
        // Reads never use a replacement left by an interrupted save; remove
        // it if that needs no prompt.
        let leftover = query(service: Self.replacementService(for: service), account: account) as CFDictionary
        _ = try? withPrompts(false) { calls.delete(leftover) }
    }

    func delete(service: String, account: String) throws {
        try deleteItem(service: service, account: account, in: nil)
        try deleteItem(service: Self.replacementService(for: service), account: account, in: nil)
    }

    /// Another build's item, in an unlocked keychain. Until the old item
    /// is deleted, reads find it, unreadable as before; after the rename
    /// they find the new password. In between they find nothing, because
    /// `get` never reads the replacement. A replacement this build can
    /// read, left by a save that stopped short, has its value changed in
    /// place. One this build cannot read is another build's and is
    /// deleted before the add. A refused delete of the old item (the user
    /// declined the prompt) removes the replacement and keeps the old item.
    private func replaceUnreadable(service: String, account: String, data: Data, in holder: SecKeychain?) throws {
        let replacement = Self.replacementService(for: service)
        let (status, _) = try read(service: replacement, account: account, in: holder)
        switch status {
        case errSecSuccess:
            try updateValue(service: replacement, account: account, data: data, in: holder)
        case errSecItemNotFound:
            try add(service: replacement, account: account, data: data, label: service, to: holder)
        default:
            guard KeychainError(status: status).isUnreadableWithoutPrompt else { throw KeychainError(status: status) }
            // Only while the keychain is unlocked does unreadable mean
            // another build's. One that locked again since the check stops
            // the save here: the delete would ask to unlock it a second time.
            guard try !isLocked(holder) else { throw KeychainError(status: errSecInteractionNotAllowed) }
            try deleteItem(service: replacement, account: account, in: holder)
            try add(service: replacement, account: account, data: data, label: service, to: holder)
        }
        do {
            try deleteItem(service: service, account: account, in: holder)
        } catch {
            // This save wrote the replacement, so this build can delete it
            // without a prompt.
            let written = query(service: replacement, account: account, in: holder) as CFDictionary
            _ = try? withPrompts(false) { calls.delete(written) }
            throw error
        }
        let renamed = query(service: replacement, account: account, in: holder) as CFDictionary
        let changes = [kSecAttrService as String: service] as CFDictionary
        let renameStatus = try withPrompts(false) { calls.update(renamed, changes) }
        guard renameStatus == errSecSuccess else { throw KeychainError(status: renameStatus) }
    }

    /// One prompt-free, in-place change of an item's value; for items this
    /// build can read, whose access list already names it.
    private func updateValue(service: String, account: String, data: Data, in holder: SecKeychain?) throws {
        let query = self.query(service: service, account: account, in: holder) as CFDictionary
        let changes = [kSecValueData as String: data] as CFDictionary
        let status = try withPrompts(false) { calls.update(query, changes) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func isLocked(_ holder: SecKeychain?) throws -> Bool {
        let (status, locked) = calls.isLocked(holder)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return locked
    }

    /// A prompt-free read of one item's value.
    private func read(service: String, account: String, in holder: SecKeychain? = nil) throws -> (OSStatus, Data?) {
        var query = self.query(service: service, account: account, in: holder)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = try withPrompts(false) { calls.copyMatching(query as CFDictionary, &item) }
        return (status, item as? Data)
    }

    /// The keychain file holding the item a read finds. Only a reference
    /// is asked for, which needs no prompt even for another build's item.
    private func keychainHolding(service: String, account: String) throws -> SecKeychain? {
        var query = self.query(service: service, account: account)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = try withPrompts(false) { calls.copyMatching(query as CFDictionary, &item) }
        guard status == errSecSuccess, let item else {
            throw KeychainError(status: status == errSecSuccess ? errSecItemNotFound : status)
        }
        let (lookup, holder) = calls.keychain(of: item)
        guard lookup == errSecSuccess else { throw KeychainError(status: lookup) }
        return holder
    }

    /// Adds with this build on the access list. A locked keychain gets the
    /// unlock prompt, on the user's own click. `label`, what Keychain Access
    /// shows, is the item's real service, which a replacement keeps after
    /// the rename.
    private func add(service: String, account: String, data: Data, label: String, to keychain: SecKeychain?) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecValueData as String: data,
            kSecAttrAccess as String: try LegacyKeychain.access(
                descriptor: Self.accessDescriptor,
                trusting: [try LegacyKeychain.thisApplication()]
            ),
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        let item = attributes as CFDictionary
        var status = try withPrompts(false) { calls.add(item) }
        if KeychainError(status: status).isUnreadableWithoutPrompt {
            status = try withPrompts(true) { calls.add(item) }
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Deletes without a prompt, or with one for another build's item: this
    /// delete is always the user's own save or clear in Settings.
    private func deleteItem(service: String, account: String, in holder: SecKeychain?) throws {
        let query = self.query(service: service, account: account, in: holder) as CFDictionary
        var status = try withPrompts(false) { calls.delete(query) }
        if KeychainError(status: status).isUnreadableWithoutPrompt {
            status = try withPrompts(true) { calls.delete(query) }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// `holder` narrows the search to the keychain that holds the item;
    /// otherwise the store's search list applies.
    private func query(service: String, account: String, in holder: SecKeychain? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let holder {
            query[kSecMatchSearchList as String] = [holder]
        } else if let searchList {
            query[kSecMatchSearchList as String] = searchList
        }
        return query
    }

    private func withPrompts<T>(_ allowed: Bool, _ body: () throws -> T) throws -> T {
        try LegacyKeychain.withPrompts(allowed, using: prompts, body)
    }
}

final class FakeKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var _unreadable: Set<String> = []
    private var _deletes: [String] = []
    /// Reads of these `service/account` keys fail the way another build's
    /// item does with prompts forbidden (errSecAuthFailed).
    var unreadable: Set<String> {
        get { lock.withLock { _unreadable } }
        set { lock.withLock { _unreadable = newValue } }
    }
    /// Every `service/account` deleted, in order.
    var deletes: [String] { lock.withLock { _deletes } }

    func get(service: String, account: String) throws -> String? {
        let key = "\(service)/\(account)"
        if unreadable.contains(key) { throw KeychainError(status: errSecAuthFailed) }
        return lock.withLock { items[key] }
    }
    func set(service: String, account: String, value: String) throws { lock.withLock { items["\(service)/\(account)"] = value } }
    func delete(service: String, account: String) throws {
        lock.withLock {
            _deletes.append("\(service)/\(account)")
            _ = items.removeValue(forKey: "\(service)/\(account)")
        }
    }
}

// MARK: - Driver

/// NWPathMonitor on Wi-Fi, one retry timer that exists only during an
/// outage, CoreWLAN for the join, handoffs.log, tmux nudge and a
/// notification on recovery. Active only while a session is active.
@MainActor
final class NetworkFailover {
    static let networksetup = "/usr/sbin/networksetup"

    /// Called after every recovery with the gap length.
    var onRecovered: ((TimeInterval) -> Void)?
    /// Called when the password report changes: set when a join is skipped
    /// for want of a readable password, nil once a read succeeds or the
    /// password is saved again.
    var onPasswordReport: ((HotspotPasswordReport?) -> Void)?

    private(set) var machine = FailoverMachine()
    private(set) var wifiInterface: String?
    private(set) var lastGap: TimeInterval?
    /// Why the last join was skipped before the join itself, if it was,
    /// and for which hotspot.
    private(set) var passwordReport: HotspotPasswordReport? {
        didSet { if passwordReport != oldValue { onPasswordReport?(passwordReport) } }
    }
    /// The hotspots whose skipped join this outage has notified, so the
    /// retries (every 5 to 30 s) do not repeat it. A hotspot configured
    /// during the outage is notified for itself. Cleared on recovery, so
    /// the next outage is notified again, and on stop and on a saved
    /// password.
    private var notifiedThisOutage: Set<String> = []

    private let paths: Paths
    private let keychain: any KeychainStoring
    private let keychainQueue: KeychainQueue
    private let nudge: TmuxNudge
    private let hotspotJoiner: any HotspotJoining
    private let notifier: any Notifying
    private let configProvider: @MainActor () -> Config
    private let clock: @Sendable () -> Date

    private var monitor: NWPathMonitor?
    private(set) var retryTimer: Timer?
    private var generation = 0
    /// Bumped by `stop()`. Work that started under an older epoch (a
    /// recovery mid-nudge) stops issuing commands as soon as it notices.
    private var epoch = 0
    /// Bumped when an outage ends, by recovery or by `stop()`. A join, and
    /// the retry its timer tick queued after it, belong to the outage they
    /// started in: a join whose keychain read waited behind a save can
    /// finish after Wi-Fi came back, and then it must not move the
    /// recovered connection to the hotspot, report a problem, or start
    /// another retry timer.
    private var outage = 0
    /// Path/timer work spawned by the driver, cancelled by `stop()`.
    private var inflight: [UUID: Task<Void, Never>] = [:]

    init(
        paths: Paths,
        keychain: any KeychainStoring = KeychainStore(),
        keychainQueue: KeychainQueue = .shared,
        nudge: TmuxNudge = TmuxNudge(),
        hotspotJoiner: any HotspotJoining = CoreWLANHotspotJoiner(),
        notifier: any Notifying,
        wifiInterface: String? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        config: @escaping @MainActor () -> Config
    ) {
        self.paths = paths
        self.keychain = keychain
        self.keychainQueue = keychainQueue
        self.nudge = nudge
        self.hotspotJoiner = hotspotJoiner
        self.notifier = notifier
        self.wifiInterface = wifiInterface
        self.clock = clock
        self.configProvider = config
    }

    func start() async {
        guard monitor == nil else { return }
        let epoch = self.epoch
        await resolveInterface()
        // stop() may have run while networksetup was being awaited.
        guard !Task.isCancelled, self.epoch == epoch else { return }
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        let id = ObjectIdentifier(m)
        m.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                // An update queued before stop() must not revive the driver.
                guard let self, let current = self.monitor, ObjectIdentifier(current) == id else { return }
                self.handlePath(satisfied: satisfied)
            }
        }
        m.start(queue: .main)
        monitor = m
        Log.info("network failover started (wifi \(wifiInterface ?? "unresolved"))")
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        cancelTimer()
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
        epoch += 1
        outage += 1
        machine = FailoverMachine()
        // The session is over: the menu line about the password goes with it.
        passwordReport = nil
        notifiedThisOutage = []
    }

    /// Settings saved or cleared the password and made `change`: forget
    /// the report unless it still stands (`HotspotPasswordReport.stands`),
    /// so the menu line goes, and forget the notifications of every other
    /// hotspot, so a problem that comes back is notified afresh.
    func passwordChanged(_ change: HotspotPasswordChange, configuredSSID: String) {
        if passwordReport?.stands(after: change, configuredSSID: configuredSSID) != true {
            passwordReport = nil
        }
        notifiedThisOutage = notifiedThisOutage.filter { $0 == passwordReport?.ssid }
    }

    /// Current SSID via `networksetup -getairportnetwork`; nil when unknown.
    func currentSSID() async -> String? {
        if wifiInterface == nil { await resolveInterface() }
        guard let iface = wifiInterface else { return nil }
        do {
            let r = try await Shell.run(Self.networksetup, ["-getairportnetwork", iface], timeout: 5)
            return HardwarePortsParser.ssid(fromGetAirportNetwork: r.stdout)
        } catch {
            Log.error("getairportnetwork failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Private

    private func resolveInterface() async {
        guard wifiInterface == nil else { return }
        do {
            let r = try await Shell.run(Self.networksetup, ["-listallhardwareports"], timeout: 5)
            wifiInterface = HardwarePortsParser.wifiInterface(from: r.stdout)
            if wifiInterface == nil {
                Log.error("could not find a Wi-Fi port in networksetup -listallhardwareports")
            } else {
                Log.info("wifi interface \(wifiInterface!)")
            }
        } catch {
            Log.error("listallhardwareports failed: \(error.localizedDescription)")
        }
    }

    /// What the NWPathMonitor calls. Internal so tests can exercise the
    /// driver-owned task without a monitor.
    func handlePath(satisfied: Bool) {
        track { [weak self] in await self?.process(satisfied: satisfied) }
    }

    /// Feed one path update through the machine and apply its outputs.
    /// Public so tests can drive the driver without an NWPathMonitor.
    func simulate(satisfied: Bool) async {
        await process(satisfied: satisfied)
    }

    /// Runs `operation` in a task that `stop()` cancels.
    @discardableResult
    private func track(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.inflight[id] = nil
        }
        inflight[id] = task
        return task
    }

    private func process(satisfied: Bool) async {
        guard !Task.isCancelled else { return }
        let now = clock()
        let outputs = satisfied ? machine.pathSatisfied(at: now) : machine.pathUnsatisfied(at: now)
        if outputs.isEmpty { return }
        if !satisfied { Log.info("wifi path unsatisfied") }
        await apply(outputs)
    }

    /// What the retry timer calls. Internal so tests can exercise the
    /// driver-owned join/retry task without waiting for a real timer; the
    /// task is returned so a test can await the tick it fired.
    @discardableResult
    func fireTimer() -> Task<Void, Never> {
        retryTimer = nil
        let outputs = machine.timerFired(at: clock())
        return track { [weak self] in await self?.apply(outputs) }
    }

    private func apply(_ outputs: [FailoverMachine.Output]) async {
        let epoch = self.epoch
        let outage = self.outage
        for o in outputs {
            // A join or recovery above may have been awaited across stop():
            // the machine is reset by then, so the remaining outputs (a retry
            // timer, most importantly) belong to a session that is gone.
            guard !Task.isCancelled, self.epoch == epoch else {
                Log.info("network failover: dropping queued outputs after stop")
                return
            }
            // The same for a join awaited across a recovery: its retry
            // belongs to the outage that just ended.
            guard self.outage == outage else {
                Log.info("network failover: dropping queued outputs after recovery")
                return
            }
            switch o {
            case let .scheduleRetry(after):
                schedule(after: after)
            case .joinHotspot:
                await joinHotspot()
            case let .recovered(start, gap):
                self.outage += 1
                cancelTimer()
                notifiedThisOutage = []
                await recovered(start: start, gap: gap)
            }
        }
    }

    private func schedule(after: TimeInterval) {
        cancelTimer()
        generation += 1
        let gen = generation
        let t = Timer(timeInterval: after, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.fireTimer()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    private func cancelTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
        generation += 1
    }

    func joinHotspot() async {
        let config = configProvider()
        let ssid = HotspotSSID.normalized(config.hotspotSSID)
        guard !ssid.isEmpty else {
            Log.info("hotspot join skipped: no hotspotSSID configured")
            return
        }
        guard let iface = wifiInterface else {
            Log.error("hotspot join skipped: no Wi-Fi interface")
            return
        }
        // Off the main actor, behind any save Settings has running, which
        // may be waiting on a keychain dialog. Everything the join depends
        // on is checked again after the wait: the session, the outage and
        // the configured SSID.
        let epoch = self.epoch
        let outage = self.outage
        let keychain = self.keychain
        let read: Result<String?, any Error>
        do {
            read = .success(try await keychainQueue.run { try keychain.get(service: KeychainStore.service, account: ssid) })
        } catch {
            read = .failure(error)
        }
        guard !Task.isCancelled, self.epoch == epoch else {
            Log.info("hotspot join dropped: the session ended during the keychain read")
            return
        }
        guard self.outage == outage else {
            Log.info("hotspot join dropped: Wi-Fi recovered during the keychain read")
            return
        }
        // Settings may have changed the hotspot meanwhile. The answer, a
        // password or a problem, is about the old one; the retry timer
        // stays, and the next tick reads the hotspot configured then.
        guard HotspotSSID.normalized(configProvider().hotspotSSID) == ssid else {
            Log.info("hotspot join dropped: the hotspot SSID changed during the keychain read")
            return
        }
        let password: String
        switch read {
        case let .success(p?):
            password = p
            passwordReport = nil
        case .success(nil):
            report(.missing, for: ssid)
            return
        case let .failure(error as KeychainError):
            report(error.problem, for: ssid)
            return
        case let .failure(error):
            report(.error(error.localizedDescription), for: ssid)
            return
        }
        Log.info("joining hotspot \(ssid) on \(iface) (attempt \(machine.joins))")
        do {
            let joined = try await hotspotJoiner.join(ssid: ssid, password: password, interfaceName: iface)
            if !joined {
                Log.error("CoreWLAN scan found no network for hotspot \(ssid); retrying with backoff")
            }
        } catch {
            Log.error("CoreWLAN hotspot join failed: \(error.localizedDescription)")
        }
    }

    /// The join is skipped: log it, show it in the menu, and notify once per
    /// outage and hotspot. The log line names the problem, not the SSID.
    private func report(_ problem: HotspotPasswordProblem, for ssid: String) {
        Log.error("hotspot join skipped: \(problem.explanation)")
        passwordReport = HotspotPasswordReport(ssid: ssid, problem: problem)
        guard notifiedThisOutage.insert(ssid).inserted else { return }
        notifier.post(title: "Hotspot not joined", body: problem.explanation)
    }

    private func recovered(start: Date, gap: TimeInterval) async {
        let epoch = self.epoch
        let end = clock()
        lastGap = gap
        let line = FailoverMachine.logLine(start: start, end: end, gap: gap)
        appendHandoff(line)
        Log.info("wifi path satisfied after \(FailoverMachine.humanGap(gap))")
        let config = configProvider()
        if gap >= config.nudgeThreshold {
            // Each pane is only nudged while this session is still the live one.
            let count = await nudge.nudge(targets: config.tmuxTargets, pressEnter: config.tmuxNudgePressesEnter) { [weak self] in self?.epoch == epoch }
            let stopped = self.epoch != epoch
            if stopped {
                Log.info("network failover stopped during recovery; \(count) tmux pane(s) had already been nudged")
            }
            // A keystroke that went out before the stop is still reported.
            if !stopped || count > 0 {
                let panes = count == 1 ? "1 tmux pane" : "\(count) tmux panes"
                notifier.post(
                    title: "Network recovered",
                    body: "Network was down \(FailoverMachine.humanGap(gap)). Nudged \(panes). Check GUI agents."
                )
            }
        }
        // A stopped driver must not write into the next session's status.
        guard self.epoch == epoch else { return }
        onRecovered?(gap)
    }

    /// Owner-only, rotated to handoffs.log.1 past OwnerOnly.maxLogBytes.
    private func appendHandoff(_ line: String) {
        do {
            try OwnerOnly.appendToLog(line + "\n", at: paths.handoffsLog)
        } catch {
            Log.error("handoffs.log: \(error.localizedDescription)")
        }
    }
}
