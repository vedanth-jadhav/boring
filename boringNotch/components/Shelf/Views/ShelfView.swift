//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit
import Defaults

struct ShelfView: View {
    let dropInteraction: DropInteractionState
    let animation: Animation?
    @StateObject var shelfState = ShelfStateViewModel.shared
    @StateObject private var tools = ShelfToolService.shared

    private let spacing: CGFloat = 8

    private var displayedItems: [ShelfItem] {
        Defaults[.reverseShelfOrdering] ? Array(shelfState.items.reversed()) : shelfState.items
    }

    var body: some View {
        @Bindable var interaction = dropInteraction
        ShelfQuickLookHost { quickLookService in
            panel(quickLookService: quickLookService)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $interaction.shelfDropTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        .onDisappear { dropInteraction.shelfDropTargeting = false }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, !ShelfSelectionModel.shared.isDragging else { return false }
        dropInteraction.dropEvent = true
        shelfState.load(providers, animation: animation)
        return true
    }

    private func panel(quickLookService: QuickLookService) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(dropInteraction.shelfDropTargeting ? Color.cyan.opacity(0.14) : Color.white.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(dropInteraction.shelfDropTargeting ? Color.cyan.opacity(0.75) : .white.opacity(0.12), lineWidth: 1)
            }
            .overlay {
                ZStack {
                    ShelfBackgroundInteractionView()
                    content(quickLookService: quickLookService)
                        .padding(8)
                }
            }

    }

    private func content(quickLookService: QuickLookService) -> some View {
        return Group {
            if shelfState.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(dropInteraction.shelfDropTargeting ? .cyan : .white.opacity(0.85))
                        .imageScale(.large)

                    Text(dropInteraction.shelfDropTargeting ? "Release to save" : "Save to Shelf")
                        .foregroundStyle(.white)
                        .font(.system(size: 14, weight: .semibold))
                    ShelfToolButton(tool: .whatsapp)
                        .frame(width: 110, height: 26)
                    Text("Drop files & screenshots here")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    Text(shelfState.importNotice ?? tools.notice)
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2).multilineTextAlignment(.center)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ScrollView(.horizontal) {
                    LazyHStack(spacing: spacing) {
                        ForEach(displayedItems) { item in
                            ShelfItemView(
                                item: item,
                                quickLookService: quickLookService,
                                dropInteraction: dropInteraction
                            )
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                    HStack(spacing: 6) {
                        ShelfToolButton(tool: .whatsapp, compact: false)
                            .frame(width: 110, height: 26)
                        if tools.isWorking || shelfState.isLoading { ProgressView().controlSize(.mini) }
                        Text(shelfState.importNotice ?? tools.notice).font(.system(size: 10)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(shelfState.items.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            shelfState.cleanupInvalidItems()
        }
    }
}

private struct ShelfBackgroundInteractionView: NSViewRepresentable {
    func makeNSView(context: Context) -> BackgroundView {
        BackgroundView()
    }

    func updateNSView(_ nsView: BackgroundView, context: Context) {}

    static func dismantleNSView(_ nsView: BackgroundView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class BackgroundView: NSView {
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()

            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window,
                  event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let contentView = window.contentView
            else { return }

            let hitPoint = contentView.convert(event.locationInWindow, from: nil)
            guard !isShelfItemInteraction(contentView.hitTest(hitPoint)) else { return }

            ShelfSelectionModel.shared.clear()
        }

        private func isShelfItemInteraction(_ hitView: NSView?) -> Bool {
            var view = hitView
            while let currentView = view {
                if currentView is any ShelfItemInteractionSurface {
                    return true
                }
                view = currentView.superview
            }
            return false
        }
    }
}

private struct ShelfQuickLookHost<Content: View>: View {
    @ViewState private var service = QuickLookService()
    @ViewBuilder let content: (QuickLookService) -> Content

    var body: some View {
        content(service)
            .quickLookPresenter(using: service)
    }
}
