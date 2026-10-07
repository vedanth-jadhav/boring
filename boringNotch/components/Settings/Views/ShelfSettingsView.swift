//
//  ShelfSettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct ShelfSettingsView: View {
    @Default(.shelfTapToOpen) var shelfTapToOpen: Bool
    @Default(.quickShareProvider) var quickShareProvider
    @Default(.expandedDragDetection) var expandedDragDetection: Bool
    @StateObject private var quickShareService = QuickShareService.shared

    private var selectedProvider: QuickShareProvider? {
        quickShareService.availableProviders.first(where: { $0.id == quickShareProvider })
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .boringShelf) {
                    Text("Enable shelf")
                }
                Defaults.Toggle(key: .openShelfByDefault) {
                    Text("Open shelf by default if items are present")
                }
                Defaults.Toggle(key: .expandedDragDetection) {
                    Text("Expanded drag detection area")
                }
                .onChange(of: expandedDragDetection) {
                    NotificationCenter.default.post(
                        name: Notification.Name.expandedDragDetectionChanged,
                        object: nil
                    )
                }
                Defaults.Toggle(key: .copyOnDrag) {
                    Text("Copy items on drag")
                }
                Defaults.Toggle(key: .autoRemoveShelfItems) {
                    Text("Remove from shelf after dragging")
                }
                Defaults.Toggle(key: .reverseShelfOrdering) {
                    Text("Keep newer shelf items in front")
                }
            } header: {
                Text("General")
            }

            Section {
                Defaults.Toggle(key: .shakeShelfTools) {
                    Text("Shake a dragged file to open quick actions")
                }
                Defaults.Toggle(key: .keepScreenshotsOnShelf) {
                    Text("Keep new screenshots in Shelf")
                }
                Text("Screenshots are copied into a lasting library. Open them in Preview for native markup. Compression makes smaller image, PDF, and video copies.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Screenshot Library") {
                    ScreenshotShelfService.shared.revealLibrary()
                }
            } header: {
                Text("File tools & screenshots")
            }

            Section {
                Picker("Quick Share Service", selection: $quickShareProvider) {
                    ForEach(quickShareService.availableProviders, id: \.id) { provider in
                        HStack {
                            Group {
                                if let icon = quickShareService.icon(for: provider.id, size: 16) {
                                    Image(nsImage: icon)
                                        .resizable().scaledToFit()
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .frame(width: 16, height: 16)
                            .foregroundColor(.accentColor)
                            Text(provider.id)
                        }
                        .tag(provider.id)
                    }
                }
                .pickerStyle(.menu)

                if let selectedProvider = selectedProvider {
                    HStack {
                        Group {
                            if let icon = quickShareService.icon(for: selectedProvider.id, size: 16) {
                                Image(nsImage: icon)
                                    .resizable().scaledToFit()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .frame(width: 16, height: 16)
                        .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Currently selected: \(selectedProvider.id)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Files dropped on the shelf will be shared via this service")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Quick Share")
                }
            } footer: {
                Text("Choose which service to use when sharing files from the shelf. Click the shelf button to select files, or drag files onto it to share immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Shelf")
    }
}
