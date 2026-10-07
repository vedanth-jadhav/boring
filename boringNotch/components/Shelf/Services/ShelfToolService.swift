import AppKit
import Combine
import SwiftUI

@MainActor
final class ShelfToolService: ObservableObject {
    static let shared = ShelfToolService()
    @Published var isWorking = false
    @Published var notice = "Shake a dragged file for quick actions" {
        didSet { ShelfToolFeedback.shared.update(notice, working: isWorking) }
    }

    func chooseFiles(for tool: ShelfTool, from view: NSView? = nil) {
        let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items).compactMap(\.fileURL)
        if !selected.isEmpty { run(tool, urls: selected, from: view); return }
        SharingStateManager.shared.beginInteraction()
        defer { SharingStateManager.shared.endInteraction() }
        let panel = NSOpenPanel()
        panel.title = tool.title
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = tool == .save || tool == .copyPath || tool == .whatsapp
        if panel.runModal() == .OK { run(tool, urls: panel.urls, from: view) }
    }

    func drop(_ providers: [NSItemProvider], tool: ShelfTool, from view: NSView? = nil) {
        Task {
            var items: [ShelfItem] = []
            for provider in providers { items.append(contentsOf: await ShelfDropService.items(from: [provider])) }
            if tool == .save { ShelfStateViewModel.shared.add(items); notice = "Saved to Shelf"; return }
            let urls = items.compactMap(\.fileURL)
            guard !urls.isEmpty else { report(ShelfMediaProcessor.failure("Drop a file for this action.")); return }
            run(tool, urls: urls, from: view)
        }
    }

    func run(_ tool: ShelfTool, urls: [URL], from view: NSView? = nil) {
        guard !urls.isEmpty else { return }
        guard tool.supports(urls) else {
            report(ShelfMediaProcessor.failure("Select compatible \(tool == .compress ? "images, PDFs, or videos" : "images or PDFs") for \(tool.title)."))
            return
        }
        if !tool.children.isEmpty {
            ShelfToolOptionsController.shared.show(tool, urls: urls)
            return
        }
        guard !isWorking else { notice = "A file tool is already working"; return }
        isWorking = true
        Task {
            ShelfToolFeedback.shared.begin(tool)
            notice = "\(tool.title)…"
            SharingStateManager.shared.beginInteraction()
            defer {
                isWorking = false
                ShelfToolFeedback.shared.update(notice, working: false)
                SharingStateManager.shared.endInteraction()
            }
            do {
                let stable = try await Task.detached(priority: .utility) {
                    try urls.map { try ShelfFileLibrary.preserveIfEphemeral($0) }
                }.value
                switch tool {
                case .whatsapp:
                    await WhatsAppShareService.share(stable)
                case .save:
                    try add(stable)
                    notice = "\(stable.count) \(stable.count == 1 ? "file" : "files") saved to Shelf"
                case .copyPath:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(stable.map(\.path).joined(separator: "\n"), forType: .string)
                    notice = "File \(stable.count == 1 ? "path" : "paths") copied"
                case .preview:
                    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { throw ShelfMediaProcessor.failure("Preview could not be found.") }
                    try await NSWorkspace.shared.open(stable, withApplicationAt: app, configuration: .init())
                    notice = "Opened in Preview · use Markup to edit"
                default:
                    if [.balanced, .smaller, .smallest].contains(tool), stable.contains(where: { $0.pathExtension.lowercased() == "pdf" }) {
                        let alert = NSAlert()
                        alert.messageText = "Compress PDF as images?"
                        alert.informativeText = "The smaller copy flattens pages. Selectable text, links, forms, and annotations become images. Your original stays available."
                        alert.addButton(withTitle: "Compress Copy")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { notice = "Compression cancelled"; return }
                    }
                    let results = try await stable.accessSecurityScopedResources { files in
                        try await Task.detached(priority: .utility) { try await ShelfMediaProcessor.process(tool, urls: files) }.value
                    }
                    try add(results)
                    let generated = results.filter { !stable.contains($0) }
                    notice = generated.isEmpty ? "Already small · original kept on Shelf" : "\(generated.count) \(generated.count == 1 ? "result" : "results") saved to Shelf"
                }
            } catch { report(error) }
        }
    }

    func add(_ urls: [URL]) throws {
        let items = try urls.map { ShelfItem(kind: .file(bookmark: try Bookmark(url: $0).data), isTemporary: false) }
        ShelfStateViewModel.shared.add(items)
    }

    func report(_ error: Error) {
        notice = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = "File action couldn’t finish"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
