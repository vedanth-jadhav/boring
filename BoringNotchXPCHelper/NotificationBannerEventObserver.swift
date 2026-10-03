import AppKit
import ApplicationServices

/// AX supplies an arrival hint only. Notification content still comes from the
/// read-only store; this class never reads text or invokes notification actions.
final class NotificationBannerEventObserver {
    private let bundleIdentifier: String
    init(bundleIdentifier: String) { self.bundleIdentifier = bundleIdentifier }
    private var observer: AXObserver?
    private var pid: pid_t?
    private var callback: ((AXUIElement) -> Void)?
    private var active = false
    func start(onEvent: @escaping (AXUIElement) -> Void) {
        DispatchQueue.main.async { self.active = true; self.callback = onEvent; self.attach() }
    }
    func refresh() { DispatchQueue.main.async { if self.active { self.attach() } } }
    func stop() { DispatchQueue.main.async { self.active = false; self.detach(); self.callback = nil } }
    private func attach() {
        guard AXIsProcessTrusted(), let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { detach(); return }
        if pid == application.processIdentifier, observer != nil { return }
        detach()
        var value: AXObserver?
        guard AXObserverCreate(application.processIdentifier, { _, element, _, context in
            guard let context else { return }
            Unmanaged<NotificationBannerEventObserver>.fromOpaque(context).takeUnretainedValue().callback?(element)
        }, &value) == .success, let value else { return }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification] {
            _ = AXObserverAddNotification(value, element, name as CFString, context)
        }
        observer = value; pid = application.processIdentifier
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
    }
    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; pid = nil
    }
}
