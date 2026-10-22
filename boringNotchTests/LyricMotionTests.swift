import XCTest
import AppKit
@testable import boringNotch

final class LyricMotionTests: XCTestCase {
    func testWordLightIsContinuousAtBothTimestamps() {
        for duration in [0.05, 0.18, 0.181, 0.5, 2.0, 8.0] {
            let word = LyricLine.Word(text: "held", start: 1, end: 1 + duration)
            for location in [0.0, 0.25, 0.5, 0.75, 1] {
                let before = LyricWordPhase(word: word, elapsed: 1 - 0.000001)
                let start = LyricWordPhase(word: word, elapsed: 1)
                let after = LyricWordPhase(word: word, elapsed: 1 + 0.000001)
                let finish = LyricWordPhase(word: word, elapsed: word.end - 0.000001)
                let completed = LyricWordPhase(word: word, elapsed: word.end)
                XCTAssertEqual(before.shimmerOpacity(at: location), start.shimmerOpacity(at: location))
                XCTAssertEqual(start.shimmerOpacity(at: location), after.shimmerOpacity(at: location), accuracy: 0.0001)
                XCTAssertEqual(finish.shimmerOpacity(at: location), completed.shimmerOpacity(at: location), accuracy: 0.0001)
            }
        }
    }

    @MainActor func testLightStopsAfterYouAndWaitsForTheActualNextWord() {
        let words: [LyricLine.Word] = [
            .init(text: "i", start: 1, end: 1.2), .init(text: "like", start: 1.2, end: 1.6),
            .init(text: "you,", start: 1.6, end: 2), .init(text: "i", start: 4, end: 4.2),
            .init(text: "dont", start: 4.2, end: 4.5), .init(text: "know", start: 4.5, end: 5)
        ]
        let layout = LyricTextLayout.cached(words: words, romanize: false, pointSize: 13, width: 430)
        let layer = LyricPaintLayer(layout: layout, words: words, visibleRange: words.indices,
            exactTiming: true, phrase: nil)
        let row = LyricVocalFrame.Row(id: "pause-after-you", words: words, isBackground: false, hasExactTiming: true)
        XCTAssertEqual(layer.light(at: 1.8, feather: 11)?.index, 2)
        for time in [0.0, 2, 2.001, 2.5, 3, 3.999999, 5, 20] {
            XCTAssertNil(layer.light(at: time, feather: 11))
            XCTAssertFalse(row.shouldAnimate(at: time, rate: 1, playing: true, reduceMotion: false))
        }
        XCTAssertEqual(layer.light(at: 4, feather: 11)?.index, 3)
        XCTAssertEqual(layer.light(at: 4.21, feather: 11)?.index, 4)
        let sample = layer.light(at: 1.8, feather: 11)!.front
        _ = layer.light(at: 4.8, feather: 11)
        XCTAssertEqual(sample, layer.light(at: 1.8, feather: 11)!.front)
    }

    @MainActor func testLineOnlyLyricsNeverGenerateASpeakingCursorOrAnimation() {
        for text in ["i like you, i dont know man hahaha", "i like you (oh) dont know", "तेरा मेरा प्यार", "Hun ki karna haan haan"] {
            let row = LyricTimeline(lines: [.init(start: 1, end: 8, text: text)]).entries[0].vocalRows.primary!
            XCTAssertEqual(row.text, text)
            let layout = LyricTextLayout.cached(words: row.words, romanize: false, pointSize: 13, width: 430)
            let layer = LyricPaintLayer(layout: layout, words: row.words, visibleRange: row.words.indices,
                exactTiming: row.hasExactTiming, phrase: .init(text: text, start: 1, end: 8))
            for frame in 0...480 {
                let time = Double(frame) / 60
                XCTAssertNil(layer.light(at: time, feather: 11))
                XCTAssertFalse(row.shouldAnimate(at: time, rate: 1, playing: true, reduceMotion: false))
                XCTAssertEqual(row.anchor(at: time), 0)
            }
        }
    }

    @MainActor func testHighlightNeverMovesOrResizesTheGlyphs() {
        let words: [LyricLine.Word] = [
            .init(text: "Élévation", start: 0, end: 1), .init(text: "ख़्वाबों", start: 1, end: 2)
        ]
        for pointSize in [CGFloat(10), 13] {
            let layout = LyricTextLayout.cached(words: words, romanize: false, pointSize: pointSize, width: 200)
            let row = LyricVocalFrame.Row(id: "fixed", words: words, isBackground: false, hasExactTiming: true)
            let configuration = LyricCanvasView(row: row, previousRow: nil, layout: layout, previousLayout: nil,
                displayStart: 0, elapsed: 0, sampleDate: .now, playbackRate: 1, isPlaying: false,
                reduceMotion: false, pointSize: pointSize)
            var expectedBounds: CGRect?
            for position in [0.0, 0.04, 0.15, 0.7, 1.1, 1.9, 2] {
                let height = Int(ceil(pointSize * 1.65 * 2))
                let context = CGContext(data: nil, width: 400, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x: 2, y: 2)
                configuration.draw(in: context, size: CGSize(width: 200, height: pointSize * 1.65), at: position)
                let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
                var bounds = CGRect.null
                for y in 0..<height {
                    for x in 0..<400 where bytes[y * context.bytesPerRow + x * 4 + 3] > 80 {
                        bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
                XCTAssertFalse(bounds.isNull)
                if let expectedBounds {
                    // Brightness can reveal one antialiased edge pixel; the glyph itself stays fixed.
                    XCTAssertTrue(abs(bounds.minX - expectedBounds.minX) <= 1)
                    XCTAssertTrue(abs(bounds.maxX - expectedBounds.maxX) <= 1)
                    XCTAssertTrue(abs(bounds.minY - expectedBounds.minY) <= 1)
                    XCTAssertTrue(abs(bounds.maxY - expectedBounds.maxY) <= 1)
                } else { expectedBounds = bounds }
            }
        }
    }

    func testHandoffKeepsIncomingReadableAndSettlesWithoutAQueuedAnimation() {
        let start = LyricHandoffPhase(start: 2, elapsed: 2)
        XCTAssertEqual(start.incomingOpacity, 0.84)
        XCTAssertEqual(start.incomingOpacity + start.outgoingOpacity, 1)
        var previous = start.incomingOpacity
        for frame in 0...20 {
            let phase = LyricHandoffPhase(start: 2, elapsed: 2 + Double(frame) / 120)
            XCTAssertTrue(phase.incomingOpacity >= previous)
            XCTAssertEqual(phase.incomingOpacity + phase.outgoingOpacity, 1)
            previous = phase.incomingOpacity
        }
        for time in [0.0, 1.999, 2.16, 20, .nan] {
            let phase = LyricHandoffPhase(start: 2, elapsed: time)
            XCTAssertEqual(phase.incomingOpacity, 1)
            XCTAssertEqual(phase.outgoingOpacity, 0)
        }
        let reduced = LyricHandoffPhase(start: 2, elapsed: 2.01, reduceMotion: true)
        XCTAssertEqual(reduced.incomingOpacity, 1)
        XCTAssertEqual(reduced.outgoingOpacity, 0)
    }

    func testHandoffPredecessorFollowsTheSelectedLeadThroughSeekAndEmptyMarkers() {
        let timeline = LyricTimeline(lines: [
            .init(start: 1, end: 3, text: "first"), .init(start: 3, end: 4, text: ""),
            .init(start: 4, end: 6, text: "second"), .init(start: 6, end: 8, text: "third")
        ])
        XCTAssertNil(timeline.previousDisplayedPrimary(at: 0))
        XCTAssertNil(timeline.previousDisplayedPrimary(at: 3.5))
        XCTAssertEqual(timeline.previousDisplayedPrimary(at: 4)?.line.text, "first")
        XCTAssertEqual(timeline.previousDisplayedPrimary(at: 7)?.line.text, "second")
        XCTAssertNil(timeline.previousDisplayedPrimary(at: 2))
        XCTAssertNil(LyricTimeline(lines: []).previousDisplayedPrimary(at: 2))
    }

    func testAnimationClockStopsForPauseSilenceBufferingAndReduceMotion() {
        let row = LyricVocalFrame.Row(id: "activity", words: [
            .init(text: "one", start: 1, end: 2), .init(text: "two", start: 3, end: 4)
        ], isBackground: false, hasExactTiming: true)
        XCTAssertTrue(row.shouldAnimate(at: 1.5, rate: 1, playing: true, reduceMotion: false))
        for time in [0.0, 2, 2.5, 4, 20, .nan] {
            XCTAssertFalse(row.shouldAnimate(at: time, rate: 1, playing: true, reduceMotion: false))
        }
        XCTAssertFalse(row.shouldAnimate(at: 1.5, rate: 1, playing: false, reduceMotion: false))
        XCTAssertFalse(row.shouldAnimate(at: 1.5, rate: 0, playing: true, reduceMotion: false))
        XCTAssertFalse(row.shouldAnimate(at: 1.5, rate: 1, playing: true, reduceMotion: true))
        XCTAssertEqual(row.animationInterval(rate: 2), 1.0 / 60)
    }

    @MainActor func testNativePaintViewStopsOnHidePauseAndDetachmentWithoutARetainCycle() {
        let row = LyricVocalFrame.Row(id: "native-lifecycle", words: [.init(text: "held", start: 0, end: 60)],
            isBackground: false, hasExactTiming: true)
        let layout = LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: false, pointSize: 13, width: 200)
        func configuration(playing: Bool) -> LyricCanvasView {
            LyricCanvasView(row: row, previousRow: nil, layout: layout, previousLayout: nil,
                displayStart: 0, elapsed: 1, sampleDate: .now, playbackRate: 1, isPlaying: playing,
                reduceMotion: false, pointSize: 13)
        }
        final class VisibleWindow: NSWindow {
            override var occlusionState: NSWindow.OcclusionState { [.visible] }
        }
        let window = VisibleWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 22),
            styleMask: [], backing: .buffered, defer: true)
        weak var released: LyricPaintView?
        autoreleasepool {
            let view = LyricPaintView(frame: window.contentLayoutRect)
            released = view
            view.update(configuration(playing: true))
            XCTAssertFalse(view.isAnimating)
            window.contentView = view
            XCTAssertTrue(view.isAnimating)
            view.isHidden = true
            XCTAssertFalse(view.isAnimating)
            view.isHidden = false
            XCTAssertTrue(view.isAnimating)
            view.update(configuration(playing: false))
            XCTAssertFalse(view.isAnimating)
            window.contentView = nil
            XCTAssertFalse(view.isAnimating)
        }
        XCTAssertNil(released)
    }
}
