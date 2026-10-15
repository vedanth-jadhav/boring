import Foundation

/// Only stores credentials obtained by this app's own authorization flow.
struct AIAccountTokenStore: Sendable {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.vedanth.boringnotch.octave/AIUsage/Tokens", isDirectory: true)
    }
    func url(for provider: AIUsageProvider) -> URL { directory.appendingPathComponent(provider.rawValue + ".json") }
    func load(_ provider: AIUsageProvider) throws -> AIAccountToken {
        guard FileManager.default.fileExists(atPath: url(for: provider).path) else { throw AccountFailure.signIn }
        return try JSONDecoder().decode(AIAccountToken.self, from: Data(contentsOf: url(for: provider)))
    }
    func save(_ token: AIAccountToken, for provider: AIUsageProvider) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(token).write(to: url(for: provider), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: provider).path)
    }
    func remove(_ provider: AIUsageProvider) throws {
        let path = url(for: provider)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    func contains(_ provider: AIUsageProvider) -> Bool { (try? load(provider)) != nil }
}
