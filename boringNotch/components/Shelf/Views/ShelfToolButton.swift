import SwiftUI

struct ShelfToolButton: View {
    let tool: ShelfTool
    var compact = false
    var action: (() -> Void)?
    @ViewState private var targeted = false
    @ViewState private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 6) {
                Group {
                    if tool == .whatsapp {
                        Image(nsImage: WhatsAppShareService.icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: tool.symbol).foregroundStyle(tool.tint)
                    }
                }
                .frame(width: compact ? 17 : 22, height: compact ? 17 : 22)
                if !compact { Text(tool.title).font(.system(size: 11, weight: .semibold)) }
                if !compact && !tool.children.isEmpty {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(height: compact ? 28 : 23)
            .padding(.horizontal, compact ? 8 : 9)
            .modifier(ShelfGlass(active: targeted || hovering, tint: tool.tint, radius: 11))
            .scaleEffect(targeted && !reduceMotion ? 1.035 : 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onHover { hovering = $0 }
        .onDrop(of: [.fileURL, .url, .image, .data], isTargeted: $targeted) { providers in
            ShelfToolService.shared.drop(providers, tool: tool)
            return true
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: targeted)
        .accessibilityLabel(tool.title)
        .help(tool.detail.isEmpty ? "Drop files here or click to use \(tool.title)" : tool.detail)
    }

    private func activate() {
        if let action { action() }
        else { ShelfToolService.shared.chooseFiles(for: tool) }
    }
}
