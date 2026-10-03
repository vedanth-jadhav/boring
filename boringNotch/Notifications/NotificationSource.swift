import Combine
import Foundation

@MainActor protocol NotificationSource {
    var events: AnyPublisher<NotificationSourceEvent, Never> { get }
    func start() async -> Bool
    func stop()
    func configure(allowed: Set<String>, allApps: Bool, ignored: Set<String>) async
}
