import Foundation
import Combine
import Defaults

extension Defaults.Keys {
    static let terminalEnabled = Key<Bool>("terminalEnabled", default: true)
    static let terminalApplication = Key<String>("terminalApplication", default: "com.apple.Terminal")
}

@main struct TerminalManagerLifecycleChecks {
    @MainActor static func count(_ url: URL) -> Int {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return contents.split(separator: "\n").count
    }

    @MainActor static func waitForCount(_ minimum: Int, _ file: URL) async throws {
        for _ in 0..<200 {
            if count(file) >= minimum { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Terminal metadata demand did not refresh")
    }

    @MainActor static func main() async throws {
        let originalEnabled = Defaults[.terminalEnabled]
        Defaults[.terminalEnabled] = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-manager-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calls = directory.appendingPathComponent("snapshots.log")
        let session = directory.appendingPathComponent("session")
        let delayNext = directory.appendingPathComponent("delay-next")
        let delayStarted = directory.appendingPathComponent("delay-started")
        let tmux = directory.appendingPathComponent("fake-tmux")
        let body = """
        #!/bin/sh
        case " $* " in
          *" has-session "*) [ -f \(TerminalSessionSupport.shellQuote(session.path)) ] && exit 0 || exit 1 ;;
          *" new-session "*) : > \(TerminalSessionSupport.shellQuote(session.path)); exit 0 ;;
          *" list-panes "*)
            result=missing
            if [ -f \(TerminalSessionSupport.shellQuote(session.path)) ]; then result=exists; fi
            printf '%s\\n' "$result" >> \(TerminalSessionSupport.shellQuote(calls.path))
            if [ -f \(TerminalSessionSupport.shellQuote(delayNext.path)) ]; then
              rm -f \(TerminalSessionSupport.shellQuote(delayNext.path))
              : > \(TerminalSessionSupport.shellQuote(delayStarted.path))
              trap '' TERM
              /bin/sleep 0.3
            fi
            if [ "$result" = exists ]; then printf '999999\\t/tmp\\n'; exit 0; else exit 1; fi
            ;;
          *) exit 1 ;;
        esac
        """
        try body.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmux.path)

        let backend = TerminalSessionBackend(tmux: tmux.path, socketName: "manager-check", sessionName: "manager-check",
                                            configurationURL: directory.appendingPathComponent("tmux.conf"))
        let manager = NotchTerminalManager(backend: backend, metadataPollInterval: .milliseconds(120))
        let first = UUID()
        let second = UUID()
        defer {
            manager.releaseMetadataDemand(first)
            manager.releaseMetadataDemand(second)
            manager.setEnabled(false)
            Defaults[.terminalEnabled] = originalEnabled
            try? FileManager.default.removeItem(at: directory)
        }

        try await waitForCount(1, calls)
        let hiddenCount = count(calls)
        try await Task.sleep(for: .milliseconds(400))
        precondition(count(calls) == hiddenCount, "Enabled terminal metadata must not poll without a visible consumer")

        manager.acquireMetadataDemand(first)
        try await waitForCount(hiddenCount + 1, calls)
        manager.acquireMetadataDemand(second)
        let twoConsumerStart = count(calls)
        try await Task.sleep(for: .milliseconds(360))
        let twoConsumerPolls = count(calls) - twoConsumerStart
        precondition((1...5).contains(twoConsumerPolls), "Two visible consumers must share one polling loop, saw \(twoConsumerPolls) polls")

        manager.releaseMetadataDemand(first)
        let remainingStart = count(calls)
        try await Task.sleep(for: .milliseconds(300))
        precondition(count(calls) > remainingStart, "One remaining consumer must keep metadata fresh")

        manager.releaseMetadataDemand(second)
        try await Task.sleep(for: .milliseconds(180))
        let releasedCount = count(calls)
        try await Task.sleep(for: .milliseconds(360))
        precondition(count(calls) == releasedCount, "The final consumer must stop recurring snapshots")

        manager.acquireMetadataDemand(first)
        await manager.start()
        precondition(manager.isRunning && FileManager.default.fileExists(atPath: session.path), "Opening the terminal starts a missing session")
        manager.releaseMetadataDemand(first)
        try FileManager.default.removeItem(at: session)
        precondition(manager.isRunning, "The test must retain a stale visible-status cache before reopening")
        manager.acquireMetadataDemand(first)
        await manager.start()
        precondition(FileManager.default.fileExists(atPath: session.path), "A stale cached running status must not skip session recovery on reveal")

        try FileManager.default.removeItem(at: session)
        try Data().write(to: delayNext)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: delayStarted.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(FileManager.default.fileExists(atPath: delayStarted.path), "The fake snapshot must capture the exited session before start")
        var watchStart = false
        var sawStaleFalseStatus = false
        let statusSubscription = manager.$isRunning.sink { isRunning in
            if watchStart && !isRunning { sawStaleFalseStatus = true }
        }
        await manager.start()
        watchStart = true
        try await Task.sleep(for: .milliseconds(500))
        precondition(manager.isRunning && !sawStaleFalseStatus,
                     "A delayed missing-session snapshot must not overwrite the successful start")
        statusSubscription.cancel()
        manager.setEnabled(false)
        manager.releaseMetadataDemand(first)
        print("PASS: hidden polling, immediate reveal refresh, shared multi-consumer polling, final release, and stale-session recovery")
    }
}
