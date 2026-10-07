import SwiftUI

struct CursorShelfView: View {
    @ObservedObject var model: CursorShelfModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.13), lineWidth: 1)
                .frame(width: model.radius * 2, height: model.radius * 2)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Image(systemName: model.selected?.symbol ?? (model.branch == nil ? "tray.and.arrow.down" : "arrow.uturn.backward"))
                    .font(.system(size: 20, weight: .medium))
                Text(model.selected?.title ?? model.branch?.title ?? "\(model.count) \(model.count == 1 ? "file" : "files")")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.selected.map { $0.children.isEmpty ? "Release to apply" : "Hold for options" } ?? (model.branch == nil ? "Drop on an action" : "Center to go back"))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: 112, height: 100)
            .modifier(ShelfGlass(radius: 40))
            ForEach(Array(model.tools.enumerated()), id: \.element.id) { index, tool in
                VStack(spacing: 5) {
                    Group {
                        if tool == .whatsapp {
                            Image(nsImage: WhatsAppShareService.icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: tool.symbol).foregroundStyle(model.selected == tool ? .white : tool.tint)
                        }
                    }
                    .frame(width: 23, height: 23)
                    HStack(spacing: 3) {
                        Text(tool.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        if !tool.children.isEmpty {
                            Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                        }
                    }
                }
                .frame(width: 86, height: 66)
                .modifier(ShelfGlass(active: model.selected == tool, tint: tool.tint, radius: 20))
                .scaleEffect(model.selected == tool && !reduceMotion ? 1.06 : 1)
                .position(model.point(for: index))
                .opacity(tool.supports(model.fileURLs) ? 1 : 0.4)
                .accessibilityLabel(tool.title)
            }
        }
        .frame(width: 420, height: 420)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: model.selected)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.branch)
        .allowsHitTesting(false)
    }
}
