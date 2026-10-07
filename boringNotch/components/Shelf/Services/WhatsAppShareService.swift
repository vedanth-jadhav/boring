import AppKit

@MainActor
enum WhatsAppShareService {
    static let provider = QuickShareProvider(id: "WhatsApp", supportsRawText: true)
    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "desktop.WhatsApp")
    }
    static var icon: NSImage {
        applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "message.fill", accessibilityDescription: "WhatsApp")!
    }

    static func customService(items: [Any]) -> NSSharingService {
        NSSharingService(title: "WhatsApp", image: icon, alternateImage: nil) {
            Task { @MainActor in await share(items) }
        }
    }

    static func share(_ items: [Any]) async {
        // Prefer a real extension when the installed application supplies one.
        let finder = ShareServiceFinder()
        if let service = await finder.findApplicableServices(for: items).first(where: {
            $0.title.localizedCaseInsensitiveContains("whatsapp")
        }), service.canPerform(withItems: items) {
            service.perform(withItems: items)
            return
        }

        // WhatsApp for Mac may ship no sharing extension. Prepare safe copies
        // for pasting; opening the app never chooses a chat or sends a message.
        ShelfToolFeedback.shared.begin(.whatsapp)
        defer { ShelfToolFeedback.shared.update(ShelfToolService.shared.notice, working: false) }
        do {
            var pasteItems: [NSPasteboardWriting] = []
            for item in items {
                if let url = item as? URL, url.isFileURL {
                    let copy = try await Task.detached(priority: .utility) {
                        try ShelfFileLibrary.preserve(url, category: "WhatsApp")
                    }.value
                    pasteItems.append(copy as NSURL)
                } else if let url = item as? URL {
                    pasteItems.append(url.absoluteString as NSString)
                } else if let text = item as? String {
                    pasteItems.append(text as NSString)
                }
            }
            guard !pasteItems.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(pasteItems)
            if let applicationURL {
                _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init())
                ShelfToolService.shared.notice = "Choose a WhatsApp chat, then paste (⌘V)"
            } else {
                NSWorkspace.shared.open(URL(string: "https://web.whatsapp.com")!)
                NSWorkspace.shared.activateFileViewerSelecting(items.compactMap { $0 as? URL }.filter(\.isFileURL))
                ShelfToolService.shared.notice = "WhatsApp Web opened · attach your files in a chat"
            }
        } catch {
            ShelfToolService.shared.report(error)
        }
    }
}
