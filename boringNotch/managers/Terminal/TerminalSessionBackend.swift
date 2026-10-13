import Foundation

// All process inspection runs away from the UI; only session metadata reaches SwiftUI.
actor TerminalSessionBackend {
    static var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private let tmux: String?
    private let configurationURL: URL
    private let socketName: String
    private let sessionName: String

    init(tmux: String? = TerminalSessionBackend.tmuxPath,
         socketName: String = TerminalSessionSupport.socketName,
         sessionName: String = TerminalSessionSupport.sessionName,
         configurationURL: URL? = nil) {
        self.tmux = tmux
        self.socketName = socketName
        self.sessionName = sessionName
        self.configurationURL = configurationURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Boring Notch/Terminal/tmux.conf")
    }

    func start() throws {
        guard let tmux else {
            throw NSError(domain: "NotchTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "tmux is needed to keep and share this shell. Install it with brew install tmux, then retry."])
        }
        if try run(tmux, arguments(["has-session", "-t", sessionName])).status == 0 { return }
        try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let safeShell = FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
        let config = """
        set -g status off
        set -g history-limit 5000
        set -g mouse on
        set -g default-terminal "tmux-256color"
        set -as terminal-features ",xterm-256color:RGB"
        set -g default-shell \(TerminalSessionSupport.shellQuote(safeShell))
        set -g default-command \(TerminalSessionSupport.shellQuote(safeShell + " -l"))
        set -g set-clipboard external
        set -g escape-time 10
        set -g focus-events on
        set -g window-size latest
        """
        try config.write(to: configurationURL, atomically: true, encoding: .utf8)
        let result = try run(tmux, arguments(["new-session", "-d", "-s", sessionName,
                                             "-x", "100", "-y", "24", "-c",
                                             FileManager.default.homeDirectoryForCurrentUser.path]))
        guard result.status == 0 else {
            throw NSError(domain: "NotchTerminal", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not start the terminal: " + result.output])
        }
    }

    func snapshot() throws -> TerminalSessionSnapshot {
        guard let tmux else { return TerminalSessionSnapshot() }
        let panes = try run(tmux, arguments(["list-panes", "-s", "-t", sessionName,
                                            "-F", "#{pane_pid}\t#{pane_current_path}"]))
        guard panes.status == 0 else { return TerminalSessionSnapshot() }
        var snapshot = TerminalSessionSnapshot(exists: true)
        var roots: Set<Int32> = []
        for line in panes.output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0 else { continue }
            roots.insert(pid)
            snapshot.directory = String(fields[1])
        }
        guard !roots.isEmpty else { return snapshot }
        let processes = try run("/bin/ps", ["-axo", "pid=,ppid="])
        let pids = TerminalSessionSupport.descendants(roots: roots, processList: processes.output)
        let listeners = try run("/usr/sbin/lsof", ["-nP", "-a", "-p",
            pids.sorted().map(String.init).joined(separator: ","), "-iTCP", "-sTCP:LISTEN", "-Fn"])
        // lsof returns 1 when there are no matching listening sockets.
        if listeners.status == 0 { snapshot.ports = TerminalSessionSupport.listeningPorts(listeners.output) }
        return snapshot
    }

    private func arguments(_ command: [String]) -> [String] {
        ["-L", socketName, "-f", configurationURL.path] + command
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
