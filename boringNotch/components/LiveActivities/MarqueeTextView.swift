//
//  MarqueeTextView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 08/08/2024.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let color: Color
    let delayDuration: Double
    let frameWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var textSize: CGSize = .zero
    @ViewState private var offset: CGFloat = 0

    init(_ text: String, font: Font = .body, nsFont: NSFont.TextStyle = .body, color: Color = .primary, delayDuration: Double = 3.0, frameWidth: CGFloat) {
        self.text = text
        self.font = font
        self.nsFont = nsFont
        self.color = color
        self.delayDuration = delayDuration
        self.frameWidth = frameWidth
    }

    private var needsScrolling: Bool {
        textSize.width > frameWidth
    }

    private struct AnimationKey: Hashable {
        let text: String
        let width: CGFloat
        let measuredWidth: CGFloat
        let reduceMotion: Bool
    }

    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 20) {
                Text(text)
                    .modifier(MeasureSizeModifier())
                if needsScrolling { Text(text) }
            }
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            // Cache the glyphs as one surface; only its transform moves.
            .drawingGroup()
            .offset(x: offset)
            .onPreferenceChange(SizePreferenceKey.self) { size in
                if textSize != size { textSize = size }
            }
            .frame(width: frameWidth, alignment: .leading)
            .clipped()
        }
        .frame(height: textSize.height * 1.3)
        .task(id: AnimationKey(text: text, width: frameWidth, measuredWidth: textSize.width, reduceMotion: reduceMotion)) {
            resetOffset()
            guard needsScrolling, !reduceMotion else { return }
            let duration = Double((textSize.width + 20) / 30)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(max(0, delayDuration))) }
                catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: duration)) { offset = -(textSize.width + 20) }
                do { try await Task.sleep(for: .seconds(duration + 2)) }
                catch { return }
                guard !Task.isCancelled else { return }
                resetOffset()
            }
        }
        .onDisappear { resetOffset() }
    }

    private func resetOffset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = 0 }
    }
}

struct TimedLyricText: View {
    let text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let color: Color
    let displayDuration: Double?
    let animationID: Double?
    let startDelay: Double
    let endLead: Double
    let frameWidth: CGFloat

    private enum TimingProfile {
        static let shortLineScrollDuration: Double = 0.35
        static let minStartDelay: Double = 0.35
        static let minScrollDuration: Double = 0.55
        static let pxPerSecond: CGFloat = 52
        static let maxBookendShare: Double = 0.42
        static let startDelayShare: Double = 0.28
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var textSize: CGSize = .zero
    @ViewState private var offset: CGFloat = 0
    @ViewState private var animationToken = UUID()

    init(
        _ text: String,
        font: Font = .body,
        nsFont: NSFont.TextStyle = .body,
        color: Color = .primary,
        displayDuration: Double? = nil,
        animationID: Double? = nil,
        startDelay: Double = 0.4,
        endLead: Double = 0.9,
        frameWidth: CGFloat
    ) {
        self.text = text
        self.font = font
        self.nsFont = nsFont
        self.color = color
        self.displayDuration = displayDuration
        self.animationID = animationID
        self.startDelay = startDelay
        self.endLead = endLead
        self.frameWidth = frameWidth
    }

    private var finalOffset: CGFloat {
        min(frameWidth - textSize.width, 0)
    }

    private var needsScrolling: Bool {
        finalOffset < 0
    }

    private var naturalScrollDuration: Double {
        max(Double(abs(finalOffset) / TimingProfile.pxPerSecond), TimingProfile.minScrollDuration)
    }

    private var animationTiming: (delay: Double, duration: Double) {
        guard let displayDuration, displayDuration > 0 else {
            return (startDelay, naturalScrollDuration)
        }

        let minimumScrollDuration = min(TimingProfile.shortLineScrollDuration, displayDuration)
        guard displayDuration > minimumScrollDuration else {
            return (0, minimumScrollDuration)
        }

        let bookendBudget = min(startDelay + endLead, displayDuration * TimingProfile.maxBookendShare)
        let delay = resolvedStartDelay(from: bookendBudget)
        let scrollDuration = max(displayDuration - bookendBudget, 0)

        return (delay, scrollDuration)
    }

    private func resolvedStartDelay(from bookendBudget: Double) -> Double {
        let dynamicDelay = bookendBudget * TimingProfile.startDelayShare
        let preferredDelay = max(TimingProfile.minStartDelay, dynamicDelay)

        return min(startDelay, preferredDelay, bookendBudget)
    }

    var body: some View {
        GeometryReader { _ in
            Text(text)
                .id(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .modifier(MeasureSizeModifier())
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    textSize = CGSize(width: size.width, height: size.height)
                    restartAnimationIfNeeded()
                }
                .onChange(of: text) { restartAnimationIfNeeded() }
                .onChange(of: frameWidth) { restartAnimationIfNeeded() }
                .onChange(of: animationID) { restartAnimationIfNeeded() }
        }
        .frame(width: frameWidth, alignment: .leading)
        .clipped()
        .frame(height: textSize.height * 1.3)
    }

    private func restartAnimationIfNeeded() {
        animationToken = UUID()
        let token = animationToken

        var resetTransaction = Transaction()
        resetTransaction.animation = nil
        withTransaction(resetTransaction) {
            offset = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            guard animationToken == token, needsScrolling, !reduceMotion else { return }
            let timing = animationTiming
            withAnimation(.linear(duration: timing.duration).delay(timing.delay)) {
                offset = finalOffset
            }
        }
    }
}
