import SwiftUI

struct CodexModelDetail: View {
    let model: CodexModelUsage
    let namespace: Namespace.ID
    @ViewState private var showsBreakdown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.id).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .matchedGeometryEffect(id: "\(model.id)-name", in: namespace, properties: .position, isSource: false)
                    .help(model.id)
                Spacer(minLength: 8)
                Text(CodexTokenTotals.compact(model.tokens.total))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .matchedGeometryEffect(id: "\(model.id)-total", in: namespace, isSource: false)
                Text(model.estimate.map { $0.formatted(.currency(code: "USD")) } ?? "—")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).monospacedDigit()
                    .matchedGeometryEffect(id: "\(model.id)-cost", in: namespace, isSource: false)
            }
            VStack(alignment: .leading, spacing: 20) {
              HStack(alignment: .top, spacing: 24) {
                column("Input", count: model.tokens.input, rate: model.rate?.input)
                column("Cached", count: model.tokens.cached, rate: model.rate?.cached)
                column("Output", count: model.tokens.output, rate: model.rate?.output)
              }
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if model.tokens.reasoning > 0 {
                        Text("\(CodexTokenTotals.compact(model.tokens.reasoning)) reasoning tokens in output")
                    }
                    if model.tokens.cacheWrite > 0 {
                        Text("\(CodexTokenTotals.compact(model.tokens.cacheWrite)) cache writes")
                    }
                }
                Spacer(minLength: 0)
                Text(model.rate == nil ? "API price unavailable" : "API prices · USD / 1M")
                    .help(model.rate?.cacheWrite.map { "Standard short-context API prices. Cache writes: \(price($0)) per million. API estimate is not your bill." }
                          ?? "Standard short-context API prices. Estimates are not subscription billing.")
              }
              .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
            }
            .opacity(showsBreakdown ? 1 : 0)
            .offset(y: showsBreakdown || reduceMotion ? 0 : 4)
            .accessibilityHidden(!showsBreakdown)
        }
        .padding(.top, 8)
        .frame(height: 172, alignment: .top)
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2).delay(0.12)) {
                showsBreakdown = true
            }
        }
    }

    private func column(_ title: String, count: Int64, rate: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            Text(CodexTokenTotals.compact(count))
                .font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
            if let rate { Text(price(rate)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(count.formatted() + " tokens" + (rate.map { " · \(price($0)) USD per 1M at Standard API prices" } ?? ""))
    }

    private func price(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(0...4)))
    }
}
