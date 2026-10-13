//
//  ShelfDropService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfDropService {
    struct ImportResult {
        let items: [ShelfItem]
        let failedCount: Int
    }

    static func items(from providers: [NSItemProvider]) async -> [ShelfItem] {
        await importItems(from: providers).items
    }

    static func importItems(from providers: [NSItemProvider]) async -> ImportResult {
        await withTaskGroup(of: (Int, ShelfItem?).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await processProvider(provider)) }
            }
            var results: [(Int, ShelfItem)] = []
            for await (index, item) in group {
                if let item { results.append((index, item)) }
            }
            return ImportResult(items: results.sorted { $0.0 < $1.0 }.map { $0.1 },
                                failedCount: providers.count - results.count)
        }
    }

    private static func processProvider(_ provider: NSItemProvider) async -> ShelfItem? {
        if let actualFileURL = await provider.extractFileURL() {
            if let bookmark = createBookmark(for: actualFileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
            return nil
        }

        if let url = await provider.extractURL() {
            if url.isFileURL {
                if let bookmark = createBookmark(for: url) {
                    return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
                }
            } else {
                return await ShelfItem(kind: .link(url: url), isTemporary: false)
            }
            return nil
        }

        if let text = await provider.extractText() {
            return await ShelfItem(kind: .text(string: text), isTemporary: false)
        }

        if let data = await provider.loadData() {
            if let tempDataURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: provider.suggestedName)),
               let bookmark = createBookmark(for: tempDataURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
            }
            return nil
        }

        if let fileURL = await provider.extractItem() {
            if let bookmark = createBookmark(for: fileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
        }

        return nil
    }

    private static func createBookmark(for url: URL) -> Data? {
        guard let stableURL = try? ShelfFileLibrary.preserveIfEphemeral(url) else { return nil }
        return (try? Bookmark(url: stableURL))?.data
    }
}
