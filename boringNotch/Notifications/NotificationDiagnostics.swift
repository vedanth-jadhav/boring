#if DEBUG
import AppKit
import Combine

@MainActor enum NotificationDiagnostics {
    static func run() async {
        let source = NotificationStoreSource()
        var count = 0, failure: String?
        let token = source.events.sink { event in
            if event.kind == .upsert { count += 1 }
            if let reason = event.failure { failure = reason.rawValue }
        }
        await source.configure(allowed: [], allApps: true, ignored: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
        let started = await source.start()
        try? await Task.sleep(for: .seconds(7))
        let observation = await XPCHelperClient.shared.notificationObservationDiagnostics()
        source.stop(); token.cancel()
        let result: [String: Any] = ["source": "usernoted-readonly", "started": started, "captured": count, "failure": failure ?? "none", "observation": observation]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
        NSApplication.shared.terminate(nil)
    }
}
#endif
