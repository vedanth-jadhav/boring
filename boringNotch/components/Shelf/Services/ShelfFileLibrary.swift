import Foundation

/// Shelf results and ephemeral drags live beyond the system temporary folder.
enum ShelfFileLibrary {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Boring Notch/Shelf Library", isDirectory: true)
    }

    static func destination(named name: String, category: String = "Tools") throws -> URL {
        let folder = root.appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    }

    static func preserve(_ url: URL, category: String = "Files") throws -> URL {
        let resolved = url.resolvingSymlinksInPath()
        if resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") { return url }
        let destination = try destination(named: url.lastPathComponent, category: category)
        try url.accessSecurityScopedResource { try FileManager.default.copyItem(at: $0, to: destination) }
        return destination
    }

    static func preserveIfEphemeral(_ url: URL) throws -> URL {
        let path = url.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/var/folders/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") {
            return try preserve(url)
        }
        return url
    }
}
