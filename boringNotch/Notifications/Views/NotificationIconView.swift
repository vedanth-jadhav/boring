import AppKit
import SwiftUI

struct NotificationIconView: View {
    let bundleID: String?
    var nativeIcon: Data? = nil
    @ViewState private var resolvedIcon: NSImage?
    var body: some View {
        Group {
            if let resolvedIcon {
                Image(nsImage: resolvedIcon).resizable().scaledToFit().scaleEffect(1.18)
            } else {
                Image(systemName: "bell.fill").font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.12))
            }
        }
        .frame(width: 29, height: 29)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .onAppear(perform: resolve)
        .onChange(of: bundleID) { _, _ in resolve() }
        .onChange(of: nativeIcon) { _, _ in resolve() }
    }
    private func resolve() {
        resolvedIcon = nativeIcon.flatMap(NSImage.init(data:)) ?? bundleID.flatMap(appIconAsNSImage(for:))
    }
}
