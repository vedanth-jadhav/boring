import SwiftUI

struct CaffeineAppRow: View {
    let app: CaffeineAppChoice
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(nsImage: app.icon).resizable().interpolation(.high)
                    .frame(width: 27, height: 27).accessibilityHidden(true)
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: app.alwaysOn ? "lock.fill" : selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: app.alwaysOn ? 10 : 18, weight: .medium))
                    .foregroundStyle(selected ? .orange : .white.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(selected && !app.alwaysOn ? 1.04 : 1)
            }
            .padding(.horizontal, 10).frame(height: 42)
            .background(selected ? Color.orange.opacity(hovering ? 0.16 : 0.10) : Color.white.opacity(hovering ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: selected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(app.name)
        .accessibilityValue(app.alwaysOn ? "Always stays active" : selected ? "Selected, keeps working" : "Not selected, pauses when lid closes")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(app.alwaysOn ? "\(app.name) always stays active." : "Includes \(app.name)’s background work.")
    }
}
