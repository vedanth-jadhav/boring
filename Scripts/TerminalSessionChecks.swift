import Foundation

@main struct TerminalSessionChecks {
    static func command(_ executable: String, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        precondition(task.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }

    static func main() async throws {
        let tick = String(UnicodeScalar(96))
        let dangerous = "a 'quote' $(touch /tmp/boring-terminal-must-not-exist) " + tick + "id" + tick + " ; \\ end\nline"
        let quoted = TerminalSessionSupport.shellQuote(dangerous)
        let roundtrip = try command("/bin/sh", ["-c", "printf %s " + quoted])
        precondition(roundtrip == dangerous, "Attach commands must quote shell metacharacters literally")
        let tree = "10 1\n11 10\n12 11\n13 12\n20 1\n21 20\n13 12\nbad\n0 10"
        precondition(TerminalSessionSupport.descendants(roots: [10], processList: tree) == [10, 11, 12, 13])
        precondition(TerminalSessionSupport.listeningPorts("p10\nn*:3000\nn[::1]:8080\nn127.0.0.1:3000\nn*:0\nn*:65536\nfbad") == [3000, 8080])
        let missing = TerminalSessionBackend(tmux: nil)
        do { try await missing.start(); preconditionFailure("Missing tmux must report an actionable error") }
        catch { precondition(error.localizedDescription.contains("brew install tmux")) }
        guard let tmux = TerminalSessionBackend.tmuxPath else {
            print("Terminal parser checks passed; tmux integration skipped (not installed).")
            return
        }
        let socket = "boring-check-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backend = TerminalSessionBackend(tmux: tmux, socketName: socket, sessionName: "check",
                                            configurationURL: directory.appendingPathComponent("tmux.conf"))
        defer {
            _ = try? command(tmux, ["-L", socket, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        let absent = try await backend.snapshot()
        precondition(!absent.exists && absent.ports.isEmpty)
        try await backend.start()
        let initial = try await backend.snapshot()
        precondition(initial.exists && initial.ports.isEmpty, "An idle shell is not a running server")
        let before = try command(tmux, ["-L", socket, "display-message", "-p", "-t", "check", "#{pane_pid}"])
        try await backend.start()
        let after = try command(tmux, ["-L", socket, "display-message", "-p", "-t", "check", "#{pane_pid}"])
        precondition(before == after, "Starting twice must reattach to the existing shell")
        let python = """
        import http.server,pathlib
        s=http.server.ThreadingHTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler)
        pathlib.Path(\(String(reflecting: directory.appendingPathComponent("port").path))).write_text(str(s.server_port))
        s.serve_forever()
        """
        let launch = "cd " + TerminalSessionSupport.shellQuote(directory.path) +
            " && /usr/bin/python3 -u -c " + TerminalSessionSupport.shellQuote(python)
        _ = try command(tmux, ["-L", socket, "send-keys", "-t", "check", "-l", launch])
        _ = try command(tmux, ["-L", socket, "send-keys", "-t", "check", "Enter"])
        var listening = TerminalSessionSnapshot()
        for _ in 0..<20 {
            listening = try await backend.snapshot()
            if !listening.ports.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let actualPort = try Int(String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8))
        precondition(listening.ports == [actualPort!], "Only this session's real listening port should appear")
        precondition(URL(fileURLWithPath: listening.directory).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path, "Track shell working directories")
        _ = try command(tmux, ["-L", socket, "send-keys", "-t", "check", "C-c"])
        var stopped = listening
        for _ in 0..<20 {
            stopped = try await backend.snapshot()
            if stopped.ports.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        precondition(stopped.exists && stopped.ports.isEmpty, "Control-C removes the server dot without killing the shell")
        print("Terminal quoting, process ownership, server lifecycle, directory, persistence, and missing-tmux checks passed.")
    }
}
