import Foundation

// A controllable space stream for exercising the production detector without changing desktops.
public actor FullScreenMonitor {
    public static let shared = FullScreenMonitor()
    public struct SpaceInfo: Sendable {
        public let runningApps: [String]
        public let screenUUID: String?
        public init(runningApps: [String], screenUUID: String?) {
            self.runningApps = runningApps
            self.screenUUID = screenUUID
        }
    }
    private var spaces: [SpaceInfo] = []
    private var continuation: AsyncStream<[SpaceInfo]>.Continuation?
    public func emit(_ spaces: [SpaceInfo]) {
        self.spaces = spaces
        continuation?.yield(spaces)
    }
    public func spaceChanges() -> AsyncStream<[SpaceInfo]> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(spaces)
        }
    }
}
