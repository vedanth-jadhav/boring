import Foundation
import Observation

/// Everything the menu shows about the machine. Updated by AppServices on
/// each OS event; `refreshOnDemand()` fills the on-demand fields (watts,
/// SSID, browser flags) when the popover opens.
@MainActor
@Observable
final class SystemStatus {
    var lidClosed: Bool = false
    var batteryPercent: Int?
    var isCharging: Bool = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    var wifiSSID: String?
    /// Length of the last Wi-Fi outage this session, in seconds.
    var lastGap: TimeInterval?
    var frozenCount: Int = 0
    var dockerPaused: Bool = false
    /// Running Chromium browsers missing the two flags.
    var throttledBrowsers: [ThrottledBrowser] = []
    /// Full detail for the relaunch item (bundle id + name).
    var browsers: [BrowserStatus] = []
    /// Why each browser's last relaunch did not happen, by bundle id: the
    /// text the notification carries, which names the browser. The menu
    /// shows each as a warning line, because a notification can be turned
    /// off for Caffeine, and one that is not presented is gone. A
    /// browser's line is cleared when its next relaunch starts, and every
    /// line when a session starts; the end of a session leaves them, since
    /// the browsers they name may still be closed.
    var relaunchProblems: [String: String] = [:]
    /// Why the failover could not join the hotspot this session, if a join
    /// was skipped for want of a readable password, and for which SSID.
    /// The menu shows it while that SSID is the one configured.
    var hotspotPasswordReport: HotspotPasswordReport?

    @ObservationIgnored var refresher: (@MainActor () async -> Void)?

    /// Fire-and-forget refresh of watts, SSID, battery and browser flags.
    func refreshOnDemand() {
        guard let refresher else { return }
        Task { @MainActor in await refresher() }
    }
}

/// Owns and wires every system integration to the SessionManager.
/// Constructed by `SessionManager.live()`; started when a session starts (or
/// is found valid at reconcile) and stopped when it ends.
@MainActor
final class AppServices {
    let status = SystemStatus()
    let notifier: any Notifying
    let locationPermission: LocationPermission

    private let paths: Paths
    private let audio: any AudioControlling
    private let display: any DisplayDimming
    private let keyboard: any KeyboardBacklighting
    private let freezer: any Freezing
    private let docker: DockerRule
    private let keychain: any KeychainStoring
    private let lid = LidObserver()
    /// The file trigger behind scripts/simulate-lid.sh. Compiled into debug
    /// builds and BORING_CAFFEINE_LID_SIMULATION release builds only
    /// (`LidSimulationBuild`); nil in every other build, and only started
    /// when `lidSimulationEnabled` is true, so a normal release build never
    /// watches the support directory for lid events.
    private let lidSimulation: (any LidSimulating)?
    private let lidSimulationEnabled: Bool
    private let power = PowerMonitor()
    private let browser: BrowserThrottle
    /// Last trusted display/keyboard brightness for the lid close (spec
    /// section 4): read every 30 s while the lid is open, at start, and 3 s
    /// after each lid open (the backlight stays suppressed briefly after the
    /// wake), and given each level the manager restores (see `follow`).
    private let sampler: BrightnessSampler
    private static let sampleInterval: TimeInterval = 30
    private static let sampleLeeway: DispatchTimeInterval = .seconds(5)
    private static let postOpenSampleDelay: Duration = .seconds(3)

    private weak var manager: SessionManager?
    private var lidActions: LidActions?
    private var floors: FloorRuleDriver?
    private var network: NetworkFailover?
    private var networkTask: Task<Void, Never>?
    private var lidTasks: [Task<Void, Never>] = []
    private var floorTasks: [Task<Void, Never>] = []
    private var browserTasks: [Task<Void, Never>] = []
    /// Relaunches started so far, and the newest one of each browser, by
    /// bundle id. Only the newest relaunch of a browser reports its outcome.
    private var relaunchCount = 0
    private var newestRelaunch: [String: Int] = [:]
    private var sampleTimer: (any DispatchSourceTimer)?
    private var postOpenSampleTask: Task<Void, Never>?
    /// The state of the last lid event, from the hinge or the simulation
    /// trigger, run or refused. `status.lidClosed` is no stand-in for it:
    /// the menu's `refreshInstant` writes the raw registry there, which
    /// can hold a change the observer then drops as a flap.
    private var lastLidEvent: Bool?
    private(set) var running = false

    init(
        paths: Paths,
        notifier: any Notifying,
        audio: any AudioControlling,
        processControl: any ProcessSignaling,
        display: any DisplayDimming = NoopDisplayDimmer(),
        keyboard: any KeyboardBacklighting = NoopKeyboardBacklight(),
        keychain: any KeychainStoring = KeychainStore(),
        locationPermission: LocationPermission = LocationPermission(),
        browser: BrowserThrottle? = nil,
        idleSeconds: @escaping @Sendable () -> Double = { UserInput.secondsSinceLastInput() },
        lidSimulation: (any LidSimulating)? = LidSimulationBuild.makeWatcher(),
        lidSimulationEnabled: Bool = LidSimulationBuild.isCompiledIn
    ) {
        self.paths = paths
        self.notifier = notifier
        self.audio = audio
        self.display = display
        self.keyboard = keyboard
        self.lidSimulation = lidSimulation
        self.lidSimulationEnabled = lidSimulationEnabled
        self.sampler = BrightnessSampler(display: display, keyboard: keyboard, idleSeconds: idleSeconds)
        self.freezer = Freezer(control: processControl)
        self.docker = DockerRule(freezer: freezer)
        self.keychain = keychain
        self.locationPermission = locationPermission
        self.browser = browser ?? BrowserThrottle()
        status.refresher = { [weak self] in await self?.refreshOnDemand() }
    }

    /// Called by SessionManager once a session is active.
    func start(for manager: SessionManager) {
        guard !running else { return }
        running = true
        self.manager = manager
        let config = manager.config
        status.lastGap = nil
        status.hotspotPasswordReport = nil
        status.relaunchProblems = [:]

        if !config.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            locationPermission.requestWhenInUse()
        }

        (notifier as? Notifier)?.requestAuthorizationIfNeeded()

        lidActions = LidActions(manager: manager, freezer: freezer, docker: docker, audio: audio, display: display, keyboard: keyboard, sampler: sampler)
        floors = FloorRuleDriver(manager: manager, notifier: notifier)
        // The panel under Caffeine's own Low Power Mode reads the mode's
        // rescaled value: sample once more just before the mode goes on
        // and keep that sample until it is off (spec section 4).
        manager.willEnableLowPower = { [weak self] in self?.sampleBrightnessIfLidOpen() }
        // A power command left running refuses lid and floor transactions
        // until it exits; the manager calls back then.
        manager.resyncAfterCommand = { [weak self] replayLid in self?.resyncAfterCommand(replayLid: replayLid) }
        sampler.follow(manager)

        lid.onChange = { [weak self] closed in self?.lidChanged(closed) }
        lid.start()
        status.lidClosed = lid.isClosed
        sampleBrightnessIfLidOpen()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.sampleInterval, repeating: Self.sampleInterval, leeway: Self.sampleLeeway)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.sampleBrightnessIfLidOpen() }
        }
        sampleTimer = timer
        timer.resume()
        startLidSimulation()

        power.onChange = { [weak self] in self?.powerChanged() }
        power.start()
        syncPower()
        // Apply the floors once: the battery may already be below one.
        powerChanged()

        let net = NetworkFailover(paths: paths, keychain: keychain, notifier: notifier) { [weak manager] in
            manager?.config ?? Config()
        }
        net.onRecovered = { [weak self] gap in self?.status.lastGap = gap }
        net.onPasswordReport = { [weak self] report in self?.status.hotspotPasswordReport = report }
        network = net
        networkTask = Task { [weak self, weak net] in
            guard let self, let net else { return }
            await net.start()
            if Task.isCancelled || !self.running || self.network !== net {
                net.stop()
            }
        }

        browserTasks.append(Task { await self.refreshBrowsers() })
        syncState()
    }

    func stop() {
        guard running else { return }
        running = false
        lid.stop()
        lid.onChange = nil
        lastLidEvent = nil
        stopLidSimulation()
        power.stop()
        power.onChange = nil
        sampleTimer?.cancel()
        sampleTimer = nil
        postOpenSampleTask?.cancel()
        postOpenSampleTask = nil
        networkTask?.cancel()
        networkTask = nil
        for task in lidTasks { task.cancel() }
        lidTasks.removeAll()
        for task in floorTasks { task.cancel() }
        floorTasks.removeAll()
        cancelBrowserTasks()
        network?.stop()
        network = nil
        status.hotspotPasswordReport = nil
        lidActions = nil
        floors = nil
        syncState()
    }

    /// One-shot launch diagnostics. This does not start any observer or retry
    /// timer, so system integrations remain active only during a session.
    func logStartupSnapshot() {
        if let closed = LidObserver.readClamshellState() {
            status.lidClosed = closed
            Log.info("startup lid state \(closed ? "closed" : "open")")
        } else {
            Log.info("startup lid state unavailable")
        }

        power.refreshBattery()
        syncPower()
        Log.info("startup battery \(PowerMonitor.describe(power.battery))")
        Log.info("startup thermal state \(PowerMonitor.name(status.thermalState))")

        Task { [weak self] in
            guard let self else { return }
            self.status.wifiSSID = await self.currentSSID()
        }
    }

    /// The part of the refresh that reads straight out of the system: battery
    /// and lid. Split out so a caller that cannot await — the right-click
    /// menu, which blocks the main actor once it is up — still opens on these.
    /// Watts are not read here: the menu calls `instantWatts()` itself.
    func refreshInstant() {
        power.refreshBattery()
        syncPower()
        if let now = LidObserver.readClamshellState() { status.lidClosed = now }
        syncState()
    }

    /// Battery + lid + SSID + browser flags. The menu kicks this off for the
    /// next opening, since the last two have to be awaited.
    func refreshOnDemand() async {
        refreshInstant()
        status.wifiSSID = await currentSSID()
        await refreshBrowsers()
    }

    /// Instant battery power, read only when requested by the UI.
    func instantWatts() -> Double? {
        power.instantWatts()
    }

    /// Cancel browser scans and relaunches in flight. `stop()` calls this
    /// when the session ends; a relaunch waiting for the browser to start
    /// then returns at once and posts nothing.
    func cancelBrowserTasks() {
        for task in browserTasks { task.cancel() }
        browserTasks.removeAll()
    }

    /// Quit and relaunch a Chromium browser with both anti-throttle flags.
    /// The outcome lands seconds after the menu click, so anything short of
    /// a relaunch goes out as a notification naming the browser, and stays
    /// in the menu in `status.relaunchProblems` until that browser's next
    /// relaunch. The bundle id and name are the ones the user confirmed,
    /// never looked up again in `status.browsers`, which a scan can replace
    /// at any point. The throttle checks the running processes itself, and
    /// a browser that is gone by then is reported as not running.
    ///
    /// The quit and start waits take seconds, and the wait for a browser to
    /// quit goes on after a cancel. When the wait is over, the outcome is
    /// reported only if the session that asked for it has not ended (a
    /// cancelled task) and no newer relaunch of the same browser has
    /// started; otherwise it is dropped, with no line and no notification,
    /// so an old outcome never stands in for a newer one.
    func relaunchUnthrottled(_ target: ThrottledBrowser) async {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.relaunchCount += 1
            let relaunch = self.relaunchCount
            self.newestRelaunch[target.bundleId] = relaunch
            self.status.relaunchProblems[target.bundleId] = nil
            let outcome = await self.browser.relaunchUnthrottled(bundleId: target.bundleId)
            guard !Task.isCancelled, self.newestRelaunch[target.bundleId] == relaunch else {
                Log.info("relaunch of \(target.bundleId) outlived its session or a newer relaunch; its outcome is dropped")
                return
            }
            if let body = outcome.explanation(browser: target.name) {
                self.status.relaunchProblems[target.bundleId] = body
                self.notifier.post(title: "Browser not relaunched", body: body)
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self.refreshBrowsers()
        }
        browserTasks.append(task)
        await task.value
    }

    /// Settings saved or cleared the hotspot password and made `change`:
    /// the menu line about the old one no longer applies, unless it is
    /// about the hotspot configured now and the save touched neither of
    /// its items (`HotspotPasswordReport.stands`), and the next outage
    /// reports afresh.
    func hotspotPasswordChanged(_ change: HotspotPasswordChange, configuredSSID: String) {
        if status.hotspotPasswordReport?.stands(after: change, configuredSSID: configuredSSID) != true {
            status.hotspotPasswordReport = nil
        }
        network?.passwordChanged(change, configuredSSID: configuredSSID)
    }

    /// Re-run the floors with the current inputs. Settings that change a
    /// floor input (the lid option) call this so the change applies now,
    /// not at the next battery, thermal or lid event. Queued on the floor
    /// chain like a power event; a no-op outside a session.
    func reevaluateFloors() {
        powerChanged()
    }

    // MARK: Lid simulation

    /// scripts/simulate-lid.sh drives the same action path as the hinge.
    /// The hardware reading in refreshInstant/reconcile still reflects the
    /// real lid; the trigger only runs the close/open actions. Nothing is
    /// wired unless the build compiled the watcher in: a release build
    /// without BORING_CAFFEINE_LID_SIMULATION has no watcher and leaves the
    /// trigger file alone. Called by `start`; internal so a test can drive
    /// it with an injected watcher.
    func startLidSimulation() {
        guard lidSimulationEnabled, let lidSimulation else { return }
        lidSimulation.onEvent = { [weak self] closed in self?.lidChanged(closed) }
        lidSimulation.start(directory: paths.appSupport, file: paths.simulateLidFile)
    }

    /// Called by `stop`; internal for the same reason.
    func stopLidSimulation() {
        guard let lidSimulation else { return }
        lidSimulation.stop()
        lidSimulation.onEvent = nil
    }

    // MARK: Private

    /// An unfinished power command has exited and the manager has checked
    /// Low Power Mode against the journal. A lid event refused while it ran
    /// is replayed for the state of the latest lid event, which runs the
    /// floors after it; otherwise the floors run now, on the corrected
    /// journal, and ask again for any Low Power change refused meanwhile.
    ///
    /// The replay waits for a hinge change still in the observer's 2 s
    /// debounce. Delivered, that change runs the actions for the new state
    /// itself, and a replay before it would run them for the state it
    /// replaces (darken and freeze with the lid open, or restore with it
    /// closed). Dropped as a flap, the replay runs then.
    private func resyncAfterCommand(replayLid: Bool) {
        guard replayLid else {
            powerChanged()
            return
        }
        lid.whenSettled { [weak self] delivered in
            guard let self, self.running, !delivered else { return }
            self.lidChanged(self.lastLidEvent ?? self.status.lidClosed)
        }
    }

    private func lidChanged(_ closed: Bool) {
        lastLidEvent = closed
        status.lidClosed = closed
        guard let actions = lidActions else { return }
        // Numbered now, not when its turn comes: an open makes a close that
        // is still queued or waiting on a Docker probe stale at once.
        let event = actions.lidEventArrived()
        let previous = lidTasks.last
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, self.running else { return }
            if closed { await actions.onClose(event: event) } else { await actions.onOpen() }
            guard !Task.isCancelled, self.running else { return }
            self.syncState()
            // The lid is a Low Power Mode cause (spec section 4): re-run the
            // floors now that the lid transaction is done. Queued on the
            // floor chain, so it stays serialized with battery events.
            self.powerChanged()
            if !closed { self.scheduleSampleAfterOpen() }
        }
        lidTasks.append(task)
    }

    /// A reading taken while the lid is closed is the darkened value, never
    /// the user's, so the sampler only runs with the lid open. The sampler
    /// itself skips anything not trustworthy at that moment.
    private func sampleBrightnessIfLidOpen() {
        guard running, !status.lidClosed else { return }
        sampler.sample()
    }

    /// The keyboard backlight stays suppressed for a moment after the wake
    /// on lid open; a sample right then would be skipped, so wait 3 s. Off
    /// the lid chain so the next lid event is not held behind the wait.
    private func scheduleSampleAfterOpen() {
        postOpenSampleTask?.cancel()
        postOpenSampleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.postOpenSampleDelay)
            guard !Task.isCancelled else { return }
            self?.sampleBrightnessIfLidOpen()
        }
    }

    private func powerChanged() {
        syncPower()
        guard let floors else { return }
        let battery = power.battery
        let charging = power.isCharging
        let thermal = power.thermalState
        let lidClosed = status.lidClosed
        let previous = floorTasks.last
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, self.running else { return }
            await floors.run(battery: battery, isCharging: charging, thermal: thermal, lidClosed: lidClosed)
            guard !Task.isCancelled, self.running else { return }
            self.syncState()
        }
        floorTasks.append(task)
    }

    private func syncPower() {
        status.batteryPercent = power.percent
        status.isCharging = power.isCharging
        status.thermalState = power.thermalState
    }

    private func syncState() {
        let s = manager?.effectiveState ?? .clean
        status.frozenCount = s.frozenPids.count
        status.dockerPaused = s.dockerFrozen
    }

    private func refreshBrowsers() async {
        let config = manager?.config ?? Config()
        let statuses = await browser.scan(config: config)
        status.browsers = statuses
        status.throttledBrowsers = browser.throttledBrowsers
    }

    private func currentSSID() async -> String? {
        if let network { return await network.currentSSID() }
        let probe = NetworkFailover(paths: paths, keychain: keychain, notifier: notifier) { Config() }
        return await probe.currentSSID()
    }
}

extension BrightnessSampler {
    /// Ties the sampler to `manager`'s journal (spec section 4). A device
    /// whose brightness is journaled is not read: it is at the 0 a lid
    /// close left, or at a level not yet decided, until its restore. An
    /// entry the manager settled but the journal has not taken yet does not
    /// count (`effectiveState`): the device is the user's again. The
    /// display is also not read while the journal on disk says Caffeine's
    /// own Low Power Mode is on, even once the mode is known off with that
    /// clear owed: the panel may still be on its way back from the mode,
    /// and the level written after it stays the sample until the clear
    /// lands. Each level the manager writes from the journal, or finds set
    /// since in place of a kept value, becomes the sample, so a lid close
    /// soon after journals that level and not a reading from before it.
    func follow(_ manager: SessionManager) {
        displayHeld = { [weak manager] in
            guard let manager else { return false }
            return manager.state.lowPowerSetByUs || manager.effectiveState.savedDisplayBrightness != nil
        }
        keyboardHeld = { [weak manager] in manager?.effectiveState.savedKeyboardBrightness != nil }
        manager.didSettleBrightness = { [weak self] display, keyboard in
            self?.record(display: display, keyboard: keyboard)
        }
    }
}
