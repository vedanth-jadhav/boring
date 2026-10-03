import Foundation

@MainActor
protocol FocusPowerManaging: AnyObject {
    @discardableResult func acquire(owner: CaffeineManager.Owner, until deadline: Date?) -> Bool
    func release(owner: CaffeineManager.Owner)
}
