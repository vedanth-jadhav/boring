import SwiftUI

struct CodexGlanceLabel: View {
    let title: String
    let value: String
    var secondaryValue: String?
    var showsTitle = true
    var status: CodexGlanceStatus = .current

    var body: some View {
        Group {
            if status == .loading || status == .unavailable || status == .resetting {
                HStack(spacing: 6) {
                    if showsTitle {
                        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.70))
                    }
                    if status == .unavailable {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    } else {
                        ProgressView().controlSize(.mini).tint(.white).frame(width: 12, height: 12)
                    }
                }
            } else {
                HStack(spacing: 5) {
                    if status == .saved {
                        Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.white.opacity(0.70))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            if showsTitle {
                                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.70))
                            }
                            Text(value).font(.system(size: 11, weight: .semibold))
                                .monospacedDigit().foregroundStyle(.white)
                                .contentTransition(.numericText())
                            if let secondaryValue {
                                Text("·").foregroundStyle(.white.opacity(0.45))
                                Text(secondaryValue).font(.system(size: 11, weight: .medium))
                                    .monospacedDigit().foregroundStyle(.white.opacity(0.70))
                            }
                        }
                        .fixedSize()
                        HStack(spacing: 6) {
                            if showsTitle { Text(title).foregroundStyle(.white.opacity(0.70)) }
                            Text(value).fontWeight(.semibold).foregroundStyle(.white)
                        }
                        .font(.system(size: 11)).monospacedDigit().fixedSize()
                        Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white).minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .opacity(status == .saved ? 0.7 : 1)
        .lineLimit(1)
    }
}
