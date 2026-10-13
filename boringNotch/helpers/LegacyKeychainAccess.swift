import Foundation
import Security

/// The login keychain uses process-level interaction controls, rather than
/// LAContext. Serialize these scoped changes and restore the prior policy.
enum LegacyKeychainAccess {
    enum PolicyError: Error { case unavailable, operation(String, OSStatus) }

    private static func requireSuccess(_ status: OSStatus, _ operation: String) throws {
        guard status == errSecSuccess else {
            NSLog("Keychain authorization %@ failed (status %d)", operation, status)
            throw PolicyError.operation(operation, status)
        }
    }
    private static let lock = NSRecursiveLock()

    static func withInteraction<T>(_ allowed: Bool, operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else { throw PolicyError.unavailable }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }

    private static func currentApplication() -> SecTrustedApplication? {
        var application: SecTrustedApplication?
        let status = SecTrustedApplicationCreateFromPath(nil, &application)
        return status == errSecSuccess ? application : nil
    }

    static func accessForCurrentApplication() -> SecAccess? {
        guard let application = currentApplication() else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Boring Notch Octave enhanced lyrics" as CFString, [application] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
    /// Retain the existing item and ACLs; authorize the signed app for secret reads only.
    static func authorizeCurrentApplication(identity: [String: Any], applicationURL: URL? = nil) throws {
        let url = applicationURL ?? (Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : Bundle.main.executableURL)
        guard let url else { throw PolicyError.unavailable }
        var application: SecTrustedApplication?
        guard url.path.withCString({ SecTrustedApplicationCreateFromPath($0, &application) }) == errSecSuccess,
              let application else { throw PolicyError.unavailable }
        var code: SecStaticCode?
        var information: CFDictionary?
        try requireSuccess(SecStaticCodeCreateWithPath(url as CFURL, [], &code), "read signed executable")
        guard let code else { throw PolicyError.unavailable }
        try requireSuccess(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information), "read signing information")
        guard let details = information as? [String: Any], let hash = details[kSecCodeInfoUnique as String] as? Data else {
            throw PolicyError.operation("missing code hash", errSecDecode)
        }
        let partition = "cdhash:" + hash.map { String(format: "%02x", $0) }.joined()
        var query = identity
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var reference: CFTypeRef?
        try requireSuccess(SecItemCopyMatching(query as CFDictionary, &reference), "find item")
        guard let reference else { throw PolicyError.unavailable }
        let item = reference as! SecKeychainItem
        var access: SecAccess?
        try requireSuccess(SecKeychainItemCopyAccess(item, &access), "read access")
        guard let access else { throw PolicyError.unavailable }
        var entries: CFArray?
        try requireSuccess(SecAccessCopyACLList(access, &entries), "read ACLs")
        guard let acls = entries as? [SecACL] else { throw PolicyError.unavailable }
        var repaired = false
        for acl in acls {
            guard let authorizations = SecACLCopyAuthorizations(acl) as? [String] else { continue }
            let isPartition = authorizations.contains(kSecACLAuthorizationPartitionID as String)
            guard isPartition || authorizations.contains(kSecACLAuthorizationDecrypt as String) else { continue }
            var applications: CFArray?
            var description: CFString?
            var prompt: SecKeychainPromptSelector = []
            try requireSuccess(SecACLCopyContents(acl, &applications, &description, &prompt), "read ACL contents")
            guard let description else { throw PolicyError.operation("missing ACL description", errSecDecode) }
            if isPartition {
                let text = description as String
                guard text.count.isMultiple(of: 2) else { throw PolicyError.operation("partition hex length", errSecDecode) }
                var data = Data()
                var index = text.startIndex
                while index < text.endIndex {
                    let end = text.index(index, offsetBy: 2)
                    guard let byte = UInt8(text[index..<end], radix: 16) else { throw PolicyError.operation("partition hex byte", errSecDecode) }
                    data.append(byte)
                    index = end
                }
                guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      var partitions = plist["Partitions"] as? [String] ?? plist["partitions"] as? [String] else { throw PolicyError.operation("partition list", errSecDecode) }
                if !partitions.contains(partition) { partitions.append(partition) }
                plist[plist["Partitions"] != nil ? "Partitions" : "partitions"] = partitions
                let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .map { String(format: "%02x", $0) }.joined()
                try requireSuccess(SecACLSetContents(acl, applications, updated as CFString, prompt), "update partition")
                repaired = true
                continue
            }
            // A nil list already permits all apps; do not narrow or broaden its existing policy.
            guard let applications else { continue }
            var trusted = applications as! [SecTrustedApplication]
            trusted.append(application)
            try requireSuccess(SecACLSetContents(acl, trusted as CFArray, description, prompt), "update trusted applications")
            repaired = true
        }
        if repaired { try requireSuccess(SecKeychainItemSetAccess(item, access), "save authorization") }
    }

}
