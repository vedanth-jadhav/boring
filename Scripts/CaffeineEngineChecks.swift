import Foundation

private enum CheckError: Error { case refused }

private actor CheckPower: SleepGuarding {
    var sleepingDisabled = false
    var lowPower = false
    let refuseStart: Bool
    init(refuseStart: Bool = false) { self.refuseStart = refuseStart }
    func setSleepDisabled(_ disabled: Bool) throws {
        if disabled && refuseStart { throw CheckError.refused }
        sleepingDisabled = disabled
    }
    func isSleepDisabled() -> Bool { sleepingDisabled }
    func setLowPowerMode(_ on: Bool) { lowPower = on }
    func isLowPowerModeOn() -> Bool { lowPower }
}

private struct CheckBackstop: BackstopScheduling {
    let refuses: Bool
    func arm() async throws { if refuses { throw CheckError.refused } }
}

private struct CheckProcesses: ProcessSignaling {
    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        preconditionFailure("Lifecycle checks must never suspend a process")
    }
    func resume(_ processes: [FrozenProcess]) -> ResumeReport {
        precondition(processes.isEmpty)
        return ResumeReport()
    }
    func cancelStops(_ processes: [FrozenProcess]) -> ResumeReport {
        precondition(processes.isEmpty)
        return ResumeReport()
    }
}

@main
private struct CaffeineEngineChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BORING_CAFFEINE_HOME"]!)
        let power = CheckPower()
        let manager = SessionManager(paths: Paths(root: root.appendingPathComponent("normal")),
            sleepGuard: power, processControl: CheckProcesses(), backstop: CheckBackstop(refuses: false), clamshell: { false })
        let engine = CaffeineEngine(manager: manager)
        await engine.prepare()
        try engine.configure(keepApps: ["example.browser"], pauseApps: ["example.chat"],
            lowPower: false, mute: true, batteryLimit: 20, protectFromHeat: true)
        check(!manager.config.disableAppNapForAgents, "selected apps do not write other apps’ sleep preferences")
        check(manager.config.agentList == ["example.browser"] && manager.config.freezeList == ["example.chat"], "app choices reach the session engine")
        check(manager.config.lowPowerFloor == 0 && manager.config.endFloor == 20, "battery reserve remains enabled with Low Power Mode off")
        var saved = try manager.store.loadConfig()!
        _ = saved.normalizeFloors()
        check(saved.lowPowerFloor == 0 && saved.endFloor == 20, "settings survive saving and normalization")
        let started = await engine.start(seconds: 60)
        check(started && engine.deadline != nil && manager.isActive, "Caffeine starts after settings are saved")
        check(await power.isSleepDisabled(), "started session holds sleep prevention")
        let stopped = await engine.stop()
        check(stopped && engine.deadline == nil && !manager.isActive, "ending Caffeine clears the active session")
        check(!(await power.isSleepDisabled()), "ending Caffeine restores sleep")
        check(!manager.state.isDirty && !FileManager.default.fileExists(atPath: manager.paths.sessionFile.path), "end leaves a clean recovery journal")
        check(await engine.start(seconds: 60), "Caffeine can start again after ending")
        check(await engine.stop(forQuit: true), "quit waits for restoration")
        check(!manager.state.isDirty, "quit leaves no work for recovery")

        for refuseBackstop in [false, true] {
            let failingPower = CheckPower(refuseStart: !refuseBackstop)
            let failingManager = SessionManager(paths: Paths(root: root.appendingPathComponent("failure-\(refuseBackstop)")),
                sleepGuard: failingPower, processControl: CheckProcesses(), backstop: CheckBackstop(refuses: refuseBackstop), clamshell: { false })
            let failingEngine = CaffeineEngine(manager: failingManager)
            let started = await failingEngine.start(seconds: 60)
            check(!started && failingEngine.deadline == nil, refuseBackstop ? "unavailable recovery refuses to start" : "failed sleep prevention never reports a running session")
            check(!(await failingPower.isSleepDisabled()) && !failingManager.state.isDirty, "failed start restores the previous state")
        }

        let identity = ProcessIdentity(startedAt: 1, startedAtMicros: 1, bootSession: "fixture")
        let processes = [
            ProcessEntry(pid: 100, ppid: 1, identity: identity, stopped: false),
            ProcessEntry(pid: 101, ppid: 100, identity: identity, stopped: false),
            ProcessEntry(pid: 200, ppid: 1, identity: identity, stopped: false),
            ProcessEntry(pid: 201, ppid: 200, identity: identity, stopped: false),
            ProcessEntry(pid: 202, ppid: 201, identity: identity, stopped: false)
        ]
        var config = Config()
        config.agentList = ["example.browser"]
        let groups = FreezePlanner.groups(bundleIds: ["example.browser", "example.chat"],
            apps: [RunningApp(pid: 100, bundleId: "example.browser", name: "Browser"), RunningApp(pid: 200, bundleId: "example.chat", name: "Chat")],
            processes: processes, config: config)
        check(groups.count == 1 && groups[0].bundleId == "example.chat", "checked apps stay out of the pause plan")
        check(groups[0].pids == [200, 201, 202], "pausing an app includes its background processes")
        let reused = SignalProcessControl(stateLookup: { _ in
            .present(ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 2, startedAtMicros: 1, bootSession: "fixture")))
        }, send: { _, _ in preconditionFailure("A reused process was signalled") })
        check(reused.resume([FrozenProcess(pid: 200, identity: identity)]).gone == [200], "recovery never resumes a reused process")
        check(CaffeineEngine.alwaysKeepsRunning("com.apple.finder") && CaffeineEngine.alwaysKeepsRunning("us.zoom.xos") && CaffeineEngine.alwaysKeepsRunning("com.objective-see.lulu.app"), "essential apps, calls and security stay protected")
        print("Caffeine engine checks passed. No system settings or running apps were changed.")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("PASS: \(message)")
    }
}
