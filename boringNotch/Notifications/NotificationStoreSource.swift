import Combine
import Foundation

/// The existing unsandboxed helper reads protected stores. Capture has no action
/// API and no dependence on Accessibility or a still-visible native banner.
@MainActor struct NotificationStoreSource: NotificationSource {
    var events: AnyPublisher<NotificationSourceEvent, Never> {
        NotificationCenter.default.publisher(for: .systemNotificationDidAppear)
            .compactMap { $0.object as? NotificationSourceEvent }.eraseToAnyPublisher()
    }
    func start() async -> Bool { await XPCHelperClient.shared.startNotificationWatching() }
    func stop() { XPCHelperClient.shared.stopNotificationWatching() }
    func configure(allowed: Set<String>, allApps: Bool, ignored: Set<String>) async {
        await XPCHelperClient.shared.configureNotificationSource(allowed: allowed, allApps: allApps, ignored: ignored)
    }
}
