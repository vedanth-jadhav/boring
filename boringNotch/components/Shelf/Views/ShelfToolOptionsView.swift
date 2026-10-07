import SwiftUI

struct ShelfToolOptionsView: View {
    let tool: ShelfTool
    let urls: [URL]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.title).font(.title2.weight(.semibold))
                    Text("\(urls.count) \(urls.count == 1 ? "file" : "files") selected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", systemImage: "xmark", action: close).labelStyle(.iconOnly).buttonStyle(.plain)
            }
            VStack(spacing: 8) {
                ForEach(tool.children) { child in
                    Button {
                        close()
                        ShelfToolService.shared.run(child, urls: urls)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: child.symbol).frame(width: 24).foregroundStyle(child.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(child.title).font(.headline)
                                if !child.detail.isEmpty { Text(child.detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                        .modifier(ShelfGlass(radius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(!child.supports(urls))
                    .opacity(child.supports(urls) ? 1 : 0.4)
                }
            }
            if tool == .compress {
                Text("Smaller copies are saved to Shelf. PDF compression flattens pages; you’ll confirm before it starts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(width: 360)
        .background(.black.opacity(0.65))
        .preferredColorScheme(.dark)
    }
}
