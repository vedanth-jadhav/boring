//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit
import SwiftUI

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { schedulePersistence() }
    }

    @Published private(set) var isLoading: Bool = false
    @Published private(set) var importNotice: String?
    private var importTask: Task<Void, Never>?
    private var pendingImports = 0
    private let persists: Bool

    var isEmpty: Bool { items.isEmpty }

    // Debounced persistence
    private var persistenceTask: Task<Void, Never>?
    private let persistenceDelay: Duration = .seconds(1)

    init(items: [ShelfItem]? = nil, persists: Bool = true) {
        self.persists = persists
        self.items = items ?? ShelfPersistenceService.shared.load()
    }

    private func schedulePersistence() {
        guard persists else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.persistenceDelay ?? .seconds(1))
            guard let self = self, !Task.isCancelled else { return }
            await ShelfPersistenceService.shared.saveAsync(self.items)
        }
    }

    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
            }
        }
        items = merged
    }

    func remove(_ item: ShelfItem) {
        item.cleanupStoredData()
        items.removeAll { $0.id == item.id }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx] = ShelfItem(id: items[idx].id, kind: .file(bookmark: bookmark), isTemporary: items[idx].isTemporary)
        }
    }

    func load(_ providers: [NSItemProvider], animation: Animation? = nil) {
        guard !providers.isEmpty else { return }
        pendingImports += 1
        isLoading = true
        let previous = importTask
        // Keep separate drops in arrival order; providers within each drop still import concurrently.
        importTask = Task { [weak self] in
            await previous?.value
            let result = await ShelfDropService.importItems(from: providers)
            guard let self else { return }
            let countBefore = self.items.count
            withAnimation(animation) { self.add(result.items) }
            let inserted = self.items.count - countBefore
            if result.failedCount > 0 {
                self.importNotice = "Couldn't import \(result.failedCount) item(s). \(inserted) added to Shelf."
            } else if inserted == 0 {
                self.importNotice = "These items are already on the Shelf."
            } else {
                self.importNotice = "Added \(inserted) item(s) to Shelf."
            }
            self.pendingImports -= 1
            self.isLoading = self.pendingImports > 0
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            await self?.cleanupInvalidItems { item in
                guard case .file(let data) = item.kind else { return true }
                return await Bookmark(data: data).validate()
            }
        }
    }

    func cleanupInvalidItems(validating validate: (ShelfItem) async -> Bool) async {
        let snapshot = items
        var invalid: [ShelfItem] = []
        for item in snapshot {
            if !(await validate(item)) { invalid.append(item) }
        }
        // Bookmark refresh, removal and insertion can all occur while validation is suspended.
        let stillInvalid = items.filter { invalid.contains($0) }
        for item in stillInvalid { item.cleanupStoredData() }
        items.removeAll { stillInvalid.contains($0) }
    }

    /// Resolves the file URL for an item and updates the bookmark if stale.
    /// Use this for user-initiated actions where bookmark refresh is desired.
    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        items.compactMap { $0.fileURL }
    }

    @MainActor
    func flushSync() {
        // Cancel any scheduled persistence task (we'll save synchronously now)
        persistenceTask?.cancel()
        persistenceTask = nil

        // Perform a synchronous, atomic save to disk
        ShelfPersistenceService.shared.save(self.items)
    }
}
