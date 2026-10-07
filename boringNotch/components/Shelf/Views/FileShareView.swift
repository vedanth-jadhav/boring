//
//  FileShareView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    let dropInteraction: DropInteractionState
    @StateObject private var quickShare = QuickShareService.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @ViewState private var hostView: NSView?
    @ViewState private var interactionNonce: UUID = .init()
    @ViewState private var isProcessing = false

    private var selectedProvider: QuickShareProvider {
        quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) ?? .systemShareMenu
    }

    var body: some View {
        @Bindable var interaction = dropInteraction

        dropArea
            .background(NSViewHost(view: $hostView))
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $interaction.dropZoneTargeting) { providers in
                interactionNonce = .init()
                interaction.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
    }

    private var dropArea: some View {
        Button {
            Task { await handleClick() }
        } label: {
            Group {
                if isProcessing || quickShare.isPickerOpen {
                    ProgressView().controlSize(.mini)
                } else if let icon = quickShare.icon(for: selectedProvider.id, size: 18) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 14))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ShelfGlass(active: dropInteraction.dropZoneTargeting, tint: .cyan, radius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share with \(selectedProvider.id)")
        .help("Share with \(selectedProvider.id) · choose a provider in Shelf settings")
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }

    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}
