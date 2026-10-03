/// One animation key for the surface's height, queue, controls and visibility.
struct NotificationSurfaceTransition: Equatable {
    let state: NotificationQueueState
    let presented: Bool
    var expanded = false
}
