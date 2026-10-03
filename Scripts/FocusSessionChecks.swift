import AppKit
import IOKit.pwr_mgt

@MainActor
private final class FakePower: FocusPowerManaging {
    var owners: Set<CaffeineManager.Owner> = []
    var succeeds = true
    func acquire(owner: CaffeineManager.Owner, until deadline: Date?) -> Bool {
        if succeeds { owners.insert(owner) }
        return succeeds
    }
    func release(owner: CaffeineManager.Owner) { owners.remove(owner) }
}

@main
struct FocusSessionChecks {
    @MainActor
    static func main() throws {
        let suiteName = "boring.focus.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let power = FakePower()
        var clock = Date()
        let manager = FocusSessionManager(defaults: defaults, power: power, now: { clock }, observeLifecycle: false)
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description)
            print("PASS: \(description)")
        }

        manager.selectedMinutes = 1
        check(manager.start(), "one-minute timer starts")
        clock = clock.addingTimeInterval(59.8)
        check(FocusSessionSnapshot.timeText(manager.session.remaining(at: clock)) == "00:01", "fractional second rounds up")
        clock = clock.addingTimeInterval(0.2)
        manager.expireIfNeeded()
        check(!manager.isActive && power.owners.isEmpty, "one-minute expiry cleans up")

        manager.selectedMinutes = 999
        manager.start()
        check(manager.session.duration == 7200, "duration is capped at two hours")
        manager.cancel()
        manager.selectedMinutes = 120
        manager.start()
        clock = clock.addingTimeInterval(61)
        check(FocusSessionSnapshot.timeText(manager.session.remaining(at: clock)) == "118:59", "60+ minute clock derives from deadline")
        manager.pause()
        let paused = manager.session.remaining(at: clock)
        clock = clock.addingTimeInterval(3600)
        check(manager.session.remaining(at: clock) == paused, "pause freezes exact remaining interval")
        check(manager.resume(), "resume starts a new absolute deadline")
        let deadline = manager.session.deadline
        manager.shutdown()
        let restored = FocusSessionManager(defaults: defaults, power: power, now: { clock }, observeLifecycle: false)
        check(restored.session.deadline == deadline, "relaunch restores original deadline")
        clock = clock.addingTimeInterval(10000)
        restored.reconcileAfterWake()
        check(!restored.isActive, "sleep or stall past deadline expires on reconciliation")
        restored.shutdown()

        manager.cancel()
        manager.selectedMode = .caffeine
        clock = Date()
        power.owners.insert(.lockScreen)
        check(manager.start() && power.owners == [.lockScreen, .focusSession], "Caffeine and lock-screen owners coexist")
        manager.pause()
        check(power.owners == [.lockScreen], "pause releases only focus assertion")
        check(manager.resume() && power.owners.count == 2, "resume reacquires focus assertion")
        manager.cancel()
        check(power.owners == [.lockScreen], "cancel preserves lock-screen owner")
        power.succeeds = false
        check(!manager.start() && !manager.isActive && manager.errorMessage != nil, "failed assertion cannot report Caffeine running")
        power.succeeds = true
        manager.start()
        clock = clock.addingTimeInterval(manager.session.duration + 1)
        manager.expireIfNeeded()
        check(power.owners == [.lockScreen], "Caffeine expiry preserves lock-screen assertion")
        manager.shutdown()

        let stale = FocusSessionSnapshot(mode: .caffeine, state: .running, duration: 60, deadline: Date().addingTimeInterval(-1))
        defaults.set(try JSONEncoder().encode(stale), forKey: FocusSessionManager.persistenceKey)
        let staleManager = FocusSessionManager(defaults: defaults, power: power, observeLifecycle: false)
        check(!staleManager.isActive && !power.owners.contains(.focusSession), "stale Caffeine never reacquires an assertion")
        staleManager.shutdown()

        // Exercise the real kernel API without UI or Accessibility permission.
        let real = CaffeineManager()
        defer { real.releaseAll() }
        check(real.acquire(owner: .lockScreen), "real lock-screen IOPM acquisition")
        check(real.acquire(owner: .focusSession, until: Date().addingTimeInterval(2)), "real focus IOPM acquisition")
        let combinedAssertions = assertionText()
        check(combinedAssertions.contains("Boring Notch: lock-screen music") && combinedAssertions.contains("Boring Notch: timed Caffeine session"), "pmset reports both callers in shared assertions")
        real.release(owner: .focusSession)
        check(real.owners == [.lockScreen], "real owner-aware release")
        check(assertionText().contains("Boring Notch: lock-screen music"), "pmset retains lock-screen assertion after focus release")
        real.release(owner: .lockScreen)
        check(real.owners.isEmpty, "real final release")
        check(!assertionText().contains("Boring Notch:"), "pmset shows cleanup after final owner")
        check(real.acquire(owner: .focusSession, until: Date().addingTimeInterval(1)), "kernel timeout acquisition")
        Thread.sleep(forTimeInterval: 1.3)
        check(!assertionText().contains("Boring Notch:"), "kernel releases expired assertions while the main thread is stalled")
        real.releaseAll()

        let kernelSession = FocusSessionManager(defaults: defaults, power: real, observeLifecycle: false)
        kernelSession.selectedMode = .caffeine
        check(kernelSession.start() && assertionText().contains("timed Caffeine session"), "Caffeine manager acquires real assertions")
        kernelSession.pause()
        check(!assertionText().contains("Boring Notch:"), "Caffeine pause releases real assertions")
        check(kernelSession.resume() && assertionText().contains("timed Caffeine session"), "Caffeine resume reacquires real assertions")
        kernelSession.cancel()
        check(!assertionText().contains("Boring Notch:"), "Caffeine cancel releases real assertions")
        kernelSession.shutdown()

        if CommandLine.arguments.contains("--live") {
            let live = FocusSessionManager(defaults: defaults, power: real, observeLifecycle: false)
            live.selectedMinutes = 1
            live.selectedMode = .caffeine
            check(live.start(), "real one-minute Caffeine starts")
            print("ASSERTIONS DURING CAFFEINE:")
            dumpAssertions()
            let end = Date().addingTimeInterval(61)
            RunLoop.main.run(until: end)
            check(!live.isActive, "real wall-clock one-minute Caffeine expires")
            print("ASSERTIONS AFTER EXPIRY:")
            dumpAssertions()
            live.shutdown()
        }
        if CommandLine.arguments.contains("--live-timer") {
            let liveTimer = FocusSessionManager(defaults: defaults, power: power, observeLifecycle: false)
            liveTimer.selectedMinutes = 1
            check(liveTimer.start(), "wall-clock one-minute Timer starts")
            RunLoop.main.run(until: Date().addingTimeInterval(61))
            check(!liveTimer.isActive, "wall-clock one-minute Timer expires without polling the model")
            liveTimer.shutdown()
        }
        print("All focus-session checks passed.")
    }

    static func assertionText() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try! task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        var own = false
        var result: [String] = []
        for line in lines {
            if line.contains("pid ") { own = line.contains("pid \(ProcessInfo.processInfo.processIdentifier)(") }
            if line.hasPrefix("Kernel Assertions") { own = false }
            if own { result.append(line) }
        }
        return result.joined(separator: "\n")
    }

    static func dumpAssertions() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "assertions"]
        try! task.run()
        task.waitUntilExit()
    }
}
