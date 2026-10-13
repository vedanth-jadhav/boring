import AppKit
import Combine
import CaffeineEngine

@MainActor
final class CaffeineSettings: ObservableObject {
    static let shared = CaffeineSettings()
    @Published private(set) var apps: [CaffeineAppChoice] = []
    @Published private(set) var loading = false
    @Published var keepApps: Set<String> { didSet { save() } }
    @Published var lowPower: Bool { didSet { save() } }
    @Published var mute: Bool { didSet { save() } }
    @Published var batteryLimit: Int { didSet { save() } }
    @Published var heatProtection: Bool { didSet { save() } }
    @Published var authorized = false
    private let defaults = UserDefaults.standard
    private var installed: [URL] = []
    private var observers: [NSObjectProtocol] = []
    private var hasSavedSelection: Bool
    private var loadTask: Task<Void, Never>?

    var keptCount: Int { apps.filter { isKept($0) }.count }
    var runningKept: [CaffeineAppChoice] { apps.filter { $0.running && isKept($0) } }

    private init() {
        hasSavedSelection = UserDefaults.standard.object(forKey: "caffeine.keepApps") != nil
        keepApps = Set(UserDefaults.standard.stringArray(forKey: "caffeine.keepApps") ?? [])
        lowPower = UserDefaults.standard.object(forKey: "caffeine.lowPower") as? Bool ?? true
        mute = UserDefaults.standard.object(forKey: "caffeine.mute") as? Bool ?? true
        batteryLimit = UserDefaults.standard.object(forKey: "caffeine.batteryLimit") as? Int ?? 10
        heatProtection = UserDefaults.standard.object(forKey: "caffeine.heatProtection") as? Bool ?? true
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            })
        }
    }

    func isKept(_ app: CaffeineAppChoice) -> Bool { app.alwaysOn || keepApps.contains(app.id) }
    func toggle(_ app: CaffeineAppChoice) {
        guard !app.alwaysOn else { return }
        if keepApps.contains(app.id) { keepApps.remove(app.id) } else { keepApps.insert(app.id) }
        hasSavedSelection = true
        FocusHaptics.action()
    }
    func keepAllRunning() {
        keepApps.formUnion(apps.filter(\.running).map(\.id))
        hasSavedSelection = true
        FocusHaptics.action()
    }

    func refresh() {
        rebuild()
        guard !loading else { return }
        loading = true
        loadTask = Task { [weak self] in
            let urls = await Task.detached(priority: .utility) { Self.installedAppURLs() }.value
            guard let self else { return }
            self.installed = urls
            self.loading = false
            self.rebuild()
            self.authorized = await FocusSessionManager.shared.caffeine.isAuthorized()
        }
    }

    func apply(to engine: CaffeineEngine) throws {
        var kept = Set(apps.filter { isKept($0) }.map(\.id))
        let keptURLs = apps.filter { isKept($0) }.map(\.url)
        let pausedURLs = apps.filter { !isKept($0) }.map(\.url)
        var paused = Set(apps.filter { !isKept($0) }.map(\.id))
        // Separately registered helper apps inherit the choice of their host.
        for running in NSWorkspace.shared.runningApplications {
            if let url = running.bundleURL, let id = running.bundleIdentifier,
               keptURLs.contains(where: { url.path.hasPrefix($0.path + "/") }) { kept.insert(id) }
            if let url = running.bundleURL, let id = running.bundleIdentifier,
               pausedURLs.contains(where: { url.path.hasPrefix($0.path + "/") }) { paused.insert(id) }
        }
        try engine.configure(keepApps: Array(kept), pauseApps: Array(paused),
                             lowPower: lowPower, mute: mute, batteryLimit: batteryLimit, protectFromHeat: heatProtection)
    }

    private func rebuild() {
        let running = NSWorkspace.shared.runningApplications
        var runningIDs: Set<String> = []
        var urls = installed
        for app in running {
            guard let url = app.bundleURL, app.activationPolicy != .prohibited else { continue }
            let host = Self.hostURL(url)
            let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
            let isInstalledApp = host.path.hasPrefix("/Applications/") || host.path.hasPrefix(userApps) || host.path.hasPrefix("/System/Applications/")
            guard app.activationPolicy == .regular || isInstalledApp else { continue }
            urls.append(host)
            if let id = Bundle(url: host)?.bundleIdentifier { runningIDs.insert(id) }
        }
        var seen: Set<String> = []
        var choices: [CaffeineAppChoice] = []
        for url in urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, !seen.contains(id) else { continue }
            // System services stay protected without filling the consumer app list.
            if id.hasPrefix("com.apple."), !runningIDs.contains(id) { continue }
            seen.insert(id)
            let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            choices.append(CaffeineAppChoice(id: id, name: name, url: url, icon: NSWorkspace.shared.icon(forFile: url.path),
                running: runningIDs.contains(id), alwaysOn: CaffeineEngine.alwaysKeepsRunning(id)))
        }
        if !hasSavedSelection {
            keepApps.formUnion(choices.filter { $0.running && CaffeineEngine.suggestedToKeep($0.id) }.map(\.id))
        }
        apps = choices.sorted {
            if $0.running != $1.running { return $0.running }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func installedAppURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/System/Applications")] {
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in iterator where url.pathExtension == "app" {
                found.append(url)
                iterator.skipDescendants()
            }
        }
        return found
    }

    private static func hostURL(_ url: URL) -> URL {
        var host = url
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension == "app" { host = parent }
            parent.deleteLastPathComponent()
        }
        return host
    }

    private func save() {
        defaults.set(Array(keepApps), forKey: "caffeine.keepApps")
        defaults.set(lowPower, forKey: "caffeine.lowPower")
        defaults.set(mute, forKey: "caffeine.mute")
        defaults.set(batteryLimit, forKey: "caffeine.batteryLimit")
        defaults.set(heatProtection, forKey: "caffeine.heatProtection")
    }
}
