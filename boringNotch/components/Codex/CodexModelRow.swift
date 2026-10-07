import SwiftUI

struct CodexModelRow: View {
    let model: CodexModelUsage
    let namespace: Namespace.ID
    let focus: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: focus) {
            HStack(spacing: 10) {
                Text(model.id).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .matchedGeometryEffect(id: "\(model.id)-name", in: namespace, properties: .position)
                    .help(model.id)
                Spacer(minLength: 8)
                Text(CodexTokenTotals.compact(model.tokens.total))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .matchedGeometryEffect(id: "\(model.id)-total", in: namespace)
                    .frame(width: 64, alignment: .trailing)
                Text(model.estimate.map { $0.formatted(.currency(code: "USD")) } ?? "—")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).monospacedDigit()
                    .matchedGeometryEffect(id: "\(model.id)-cost", in: namespace)
                    .frame(width: 76, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.4)).frame(width: 8)
            }
            .frame(minHeight: 34).contentShape(Rectangle())
            .background(.white.opacity(hovering ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(model.id), \(model.tokens.total.formatted()) tokens. View token breakdown and API pricing")
    }
}
