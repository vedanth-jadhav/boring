import AppKit
import CryptoKit
import Defaults
import ImageIO
import PDFKit

@MainActor
final class ScreenshotShelfService {
    static let shared = ScreenshotShelfService()
    private var task: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private let scanner = ScreenshotLibraryScanner()

    func start() {
        guard task == nil else { return }
        watchDirectories()
        task = Task { [weak self] in
            while !Task.isCancelled {
                if Defaults[.boringShelf], Defaults[.keepScreenshotsOnShelf], let self {
                    await self.importScreenshots()
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        scanTask?.cancel(); scanTask = nil
        watchers.forEach { $0.cancel() }; watchers.removeAll()
    }

    private func importScreenshots() async {
        guard Defaults[.boringShelf], Defaults[.keepScreenshotsOnShelf] else { return }
        let imported = await scanner.scan()
        guard !imported.isEmpty else { return }
        do {
            try ShelfToolService.shared.add(imported)
            if !ShelfToolService.shared.isWorking {
                ShelfToolService.shared.notice = "Screenshot saved · open in Preview to edit"
            }
        } catch { Log.shelf.error("Screenshot library: \(error.localizedDescription)") }
    }

    private func watchDirectories() {
        let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") ?? "~/Desktop"
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let paths = [temp.path, temp.appendingPathComponent("TemporaryItems").path, (location as NSString).expandingTildeInPath]
        for path in Set(paths) {
            let descriptor = Darwin.open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.scanTask?.cancel()
                    self.scanTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        await self?.importScreenshots()
                    }
                }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    func capture() {
        let app = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
            if let error { Task { @MainActor in ShelfToolService.shared.report(error) } }
        }
    }

    func revealLibrary() {
        let directory = ShelfFileLibrary.root.appendingPathComponent("Screenshots", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); NSWorkspace.shared.open(directory) }
        catch { ShelfToolService.shared.report(error) }
    }
}

private actor ScreenshotLibraryScanner {
    private let started = Date()
    private var observed: [String: String] = [:]
    private var processed: Set<String> = []
    private var hashes: Set<String> = []
    private var loadedIndex = false

    func scan() -> [URL] {
        let fm = FileManager.default
        let library = ShelfFileLibrary.root.appendingPathComponent("Screenshots", isDirectory: true)
        let index = library.appendingPathComponent("index.json")
        if !loadedIndex {
            hashes = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: index))) ?? []
            loadedIndex = true
        }
        let prefs = UserDefaults(suiteName: "com.apple.screencapture")
        let location = prefs?.string(forKey: "location") ?? "~/Desktop"
        let output = URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
        let prefix = prefs?.string(forKey: "name") ?? "Screenshot"
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var candidates = (try? fm.contentsOfDirectory(at: output, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        candidates = candidates.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(prefix) || name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot")
        }
        // The floating ⌘⇧5 thumbnail is stored here before the chosen output is
        // written. Scan only screencaptureui containers, never the whole /tmp tree.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let temporaryItems = temp.appendingPathComponent("TemporaryItems", isDirectory: true)
        for root in [temp, temporaryItems] {
            let directories = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for directory in directories where directory.lastPathComponent.contains("screencaptureui") {
                candidates.append(contentsOf: (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? [])
            }
        }
        var imported: [URL] = []
        var currentObserved: [String: String] = [:]
        for url in candidates where ["png", "jpg", "jpeg", "heic", "tiff", "pdf"].contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= started, let size = values.fileSize, size > 0 else { continue }
            let signature = "\(url.path)|\(size)|\(modified.timeIntervalSince1970)"
            currentObserved[url.path] = signature
            let ephemeral = url.path.contains("screencaptureui")
            guard (ephemeral || observed[url.path] == signature), !processed.contains(signature) else { continue }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if url.pathExtension.lowercased() == "pdf" {
                    guard let document = PDFDocument(data: data), document.pageCount > 0 else { continue }
                } else {
                    guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetStatus(image) == .statusComplete else { continue }
                }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if !hashes.contains(hash) {
                    let destination = try ShelfFileLibrary.destination(named: url.lastPathComponent, category: "Screenshots")
                    try data.write(to: destination, options: .atomic)
                    imported.append(destination)
                    hashes.insert(hash)
                    try JSONEncoder().encode(hashes).write(to: index, options: .atomic)
                }
                processed.insert(signature)
            } catch { Log.shelf.error("Could not preserve screenshot: \(error.localizedDescription)") }
        }
        observed = currentObserved
        if processed.count > 2000 { processed = Set(currentObserved.values.filter { processed.contains($0) }) }
        return imported
    }
}
