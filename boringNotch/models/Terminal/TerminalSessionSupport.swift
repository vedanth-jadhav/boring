import Foundation

enum TerminalSessionSupport {
    static let socketName = "boring-notch"
    static let sessionName = "notch"

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func attachCommand(tmux: String) -> String {
        [tmux, "-L", socketName, "attach-session", "-t", sessionName]
            .map(shellQuote).joined(separator: " ")
    }

    static func descendants(roots: Set<Int32>, processList: String) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for line in processList.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  pid > 0, parent > 0 else { continue }
            children[parent, default: []].append(pid)
        }
        var result = roots
        var pending = Array(roots)
        while let pid = pending.popLast() {
            for child in children[pid, default: []] where result.insert(child).inserted {
                pending.append(child)
            }
        }
        return result
    }

    static func listeningPorts(_ output: String) -> [Int] {
        Set(output.split(separator: "\n").compactMap { line -> Int? in
            guard line.first == "n", let port = line.split(separator: ":").last.flatMap({ Int($0) }),
                  (1...65535).contains(port) else { return nil }
            return port
        }).sorted()
    }
}
