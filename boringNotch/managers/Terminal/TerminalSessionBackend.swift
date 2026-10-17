import Foundation
import Darwin

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

    func start() async throws {
        guard let tmux else {
            throw NSError(domain: "NotchTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "tmux is needed to keep and share this shell. Install it with brew install tmux, then retry."])
        }
        if try await run(tmux, arguments(["has-session", "-t", sessionName])).status == 0 { return }
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
        let result = try await run(tmux, arguments(["new-session", "-d", "-s", sessionName,
                                             "-x", "100", "-y", "24", "-c",
                                             FileManager.default.homeDirectoryForCurrentUser.path]))
        guard result.status == 0 else {
            throw NSError(domain: "NotchTerminal", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not start the terminal: " + result.output])
        }
    }

    func snapshot() async throws -> TerminalSessionSnapshot {
        guard let tmux else { return TerminalSessionSnapshot() }
        let panes = try await run(tmux, arguments(["list-panes", "-s", "-t", sessionName,
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
        let processes = try await run("/bin/ps", ["-axo", "pid=,ppid="])
        let pids = TerminalSessionSupport.descendants(roots: roots, processList: processes.output)
        let listeners = try await run("/usr/sbin/lsof", ["-nP", "-a", "-p",
            pids.sorted().map(String.init).joined(separator: ","), "-iTCP", "-sTCP:LISTEN", "-Fn"])
        // lsof returns 1 when there are no matching listening sockets.
        if listeners.status == 0 { snapshot.ports = TerminalSessionSupport.listeningPorts(listeners.output) }
        return snapshot
    }

    private func arguments(_ command: [String]) -> [String] {
        ["-L", socketName, "-f", configurationURL.path] + command
    }

    private func run(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("boring-terminal-\(UUID().uuidString).log")
        // Detached descendants cannot keep this output open and block command completion.
        let outputDescriptor = Darwin.open(outputURL.path, O_CREAT | O_EXCL | O_RDWR, mode_t(0o600))
        guard outputDescriptor >= 0 else { throw terminalError("Could not create terminal command output", errno) }
        defer {
            _ = Darwin.close(outputDescriptor)
            try? FileManager.default.removeItem(at: outputURL)
        }

        var fileActions: posix_spawn_file_actions_t?
        let fileActionsInit = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsInit == 0 else { throw terminalError("Could not prepare terminal command output", fileActionsInit) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var fileActionStatus = posix_spawn_file_actions_adddup2(&fileActions, outputDescriptor, STDOUT_FILENO)
        if fileActionStatus == 0 {
            fileActionStatus = posix_spawn_file_actions_adddup2(&fileActions, outputDescriptor, STDERR_FILENO)
        }
        if fileActionStatus == 0 {
            fileActionStatus = posix_spawn_file_actions_addclose(&fileActions, outputDescriptor)
        }
        guard fileActionStatus == 0 else { throw terminalError("Could not prepare terminal command output", fileActionStatus) }

        var attributes: posix_spawnattr_t?
        let attributesInit = posix_spawnattr_init(&attributes)
        guard attributesInit == 0 else { throw terminalError("Could not prepare terminal command", attributesInit) }
        defer { posix_spawnattr_destroy(&attributes) }
        let attributeStatus = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        guard attributeStatus == 0 else { throw terminalError("Could not isolate terminal command", attributeStatus) }
        let groupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupStatus == 0 else { throw terminalError("Could not isolate terminal command", groupStatus) }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "en_US.UTF-8"
        let strings = [executable] + arguments + environment.map { "\($0.key)=\($0.value)" }
        let pointers = strings.map { $0.withCString { strdup($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.compactMap { $0 }.forEach { Darwin.free($0) }
            throw terminalError("Could not prepare terminal command arguments", ENOMEM)
        }
        defer { pointers.compactMap { $0 }.forEach { Darwin.free($0) } }
        let argumentPointers = Array(pointers[0..<(arguments.count + 1)]) + [nil]
        let environmentPointers = Array(pointers[(arguments.count + 1)...]) + [nil]

        var processID: pid_t = 0
        let spawnStatus = argumentPointers.withUnsafeBufferPointer { argv in
            environmentPointers.withUnsafeBufferPointer { envp in
                guard let argvBase = argv.baseAddress, let envpBase = envp.baseAddress else { return EINVAL }
                return posix_spawn(&processID, executable, &fileActions, &attributes, argvBase, envpBase)
            }
        }
        guard spawnStatus == 0 else { throw terminalError("Could not run terminal command", spawnStatus) }

        let deadline = ContinuousClock.now + .seconds(3)
        var waitStatus: Int32 = 0
        while true {
            if Task.isCancelled {
                waitStatus = await terminate(processID, waitStatus: waitStatus)
                throw CancellationError()
            }
            let result = waitpid(processID, &waitStatus, WNOHANG)
            if result == processID { break }
            if result < 0 && errno != EINTR { throw terminalError("Could not wait for terminal command", errno) }
            if ContinuousClock.now >= deadline {
                _ = await terminate(processID, waitStatus: waitStatus)
                throw terminalError("Terminal command exceeded its three-second deadline", ETIMEDOUT)
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                waitStatus = await terminate(processID, waitStatus: waitStatus)
                throw CancellationError()
            }
        }

        let data = try Data(contentsOf: outputURL)
        return (statusCode(waitStatus), String(decoding: data, as: UTF8.self))
    }

    private func terminate(_ processID: pid_t, waitStatus: Int32) async -> Int32 {
        var status = waitStatus
        let initialResult = waitpid(processID, &status, WNOHANG)
        var reaped = initialResult == processID || (initialResult < 0 && errno == ECHILD)
        _ = kill(-processID, SIGTERM)
        let graceDeadline = ContinuousClock.now + .milliseconds(150)
        while ContinuousClock.now < graceDeadline {
            if !reaped {
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID || (result < 0 && errno == ECHILD) { reaped = true }
            }
            await pauseIgnoringCancellation(.milliseconds(15))
        }
        if processGroupExists(processID) { _ = kill(-processID, SIGKILL) }
        let reapDeadline = ContinuousClock.now + .seconds(1)
        while !reaped && ContinuousClock.now < reapDeadline {
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID || (result < 0 && errno == ECHILD) { reaped = true; break }
            await pauseIgnoringCancellation(.milliseconds(15))
        }
        return reaped ? status : 128 + SIGKILL
    }

    private func processGroupExists(_ processID: pid_t) -> Bool {
        if kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func pauseIgnoringCancellation(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            Task {
                try? await Task.sleep(for: duration)
                continuation.resume()
            }
        }
    }

    private func statusCode(_ status: Int32) -> Int32 {
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    private func terminalError(_ message: String, _ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
