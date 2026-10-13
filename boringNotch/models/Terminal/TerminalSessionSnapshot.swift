import Foundation

struct TerminalSessionSnapshot: Sendable {
    var exists = false
    var directory = FileManager.default.homeDirectoryForCurrentUser.path
    var ports: [Int] = []
}
