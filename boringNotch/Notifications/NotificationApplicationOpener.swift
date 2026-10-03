import AppKit

@MainActor enum NotificationApplicationOpener {
    struct Application { let url: URL; let bundleID: String; let name: String }
    static func application(for notification: MirroredNotification) -> Application? {
        guard let id = notification.bundleID else { return nil }
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.caseInsensitiveCompare(id) == .orderedSame }
        guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let bundle = Bundle(url: url)
        return .init(url: url, bundleID: bundle?.bundleIdentifier ?? id,
                     name: running?.localizedName ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent)
    }
    static func open(_ notification: MirroredNotification) async -> Bool {
        guard let app = application(for: notification) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do { _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration); return true }
        catch { return false }
    }
}
