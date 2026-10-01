import XCTest
@testable import boringNotch

final class LyricsPrecisionTests: XCTestCase {
    func testHighlightBoundariesUseMillisecondsWithoutAnimationLag() {
        let word = LyricLine.Word(text: "दिल", start: 10.125, end: 10.425)
        XCTAssertFalse(LyricWordPhase(word: word, elapsed: 10.124).isActive)
        XCTAssertTrue(LyricWordPhase(word: word, elapsed: 10.125).isActive)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 10.275).progress, 0.5, accuracy: 0.000001)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 10.275).illumination, 1)
        XCTAssertFalse(LyricWordPhase(word: word, elapsed: 10.425).isActive)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 10.425).illumination, 0)
    }

    func testFastRapWordsDoNotInheritLongFades() {
        let first = LyricLine.Word(text: "one", start: 1, end: 1.05)
        let next = LyricLine.Word(text: "two", start: 1.05, end: 1.10)
        XCTAssertEqual(LyricWordPhase(word: first, elapsed: 1.025).illumination, 1)
        XCTAssertFalse(LyricWordPhase(word: first, elapsed: 1.05).isActive)
        XCTAssertTrue(LyricWordPhase(word: next, elapsed: 1.05).isActive)
        XCTAssertEqual(LyricWordPhase(word: next, elapsed: 1.075).illumination, 1)
    }

    func testPauseAndSeekFramesAreDeterministic() {
        let word = LyricLine.Word(text: "ohh", start: 3, end: 5)
        let before = LyricWordPhase(word: word, elapsed: 3.875)
        _ = LyricWordPhase(word: word, elapsed: 12)
        let afterSeek = LyricWordPhase(word: word, elapsed: 3.875)
        XCTAssertEqual(before.progress, afterSeek.progress)
        XCTAssertEqual(before.illumination, afterSeek.illumination)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: .nan).illumination, 0)
    }

    func testBrowserTransportLatencyIsNotAddedToLyrics() {
        let received = Date(timeIntervalSince1970: 1234.078)
        let sampled = LyricPlaybackClock.sampleDate(milliseconds: 1234025, receivedAt: received)
        XCTAssertEqual(sampled.timeIntervalSince1970, 1234.025, accuracy: 0.000001)
        XCTAssertEqual(received.timeIntervalSince(sampled), 0.053, accuracy: 0.000001)
        XCTAssertEqual(LyricPlaybackClock.sampleDate(milliseconds: nil, receivedAt: received), received)
        XCTAssertEqual(LyricPlaybackClock.sampleDate(milliseconds: .nan, receivedAt: received), received)
        XCTAssertEqual(LyricPlaybackClock.sampleDate(milliseconds: 1, receivedAt: received), received)
    }

    func testSmallClockErrorsAreCorrectedAndPlaybackRateIsRespected() {
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(LyricPlaybackClock.needsCorrection(position: 11.03, sampleDate: date.addingTimeInterval(1),
            anchorPosition: 10, anchorDate: date, rate: 1, playing: true))
        XCTAssertFalse(LyricPlaybackClock.needsCorrection(position: 12.005, sampleDate: date.addingTimeInterval(1),
            anchorPosition: 10, anchorDate: date, rate: 2, playing: true))
        XCTAssertFalse(LyricPlaybackClock.needsCorrection(position: 10, sampleDate: date.addingTimeInterval(1),
            anchorPosition: 10, anchorDate: date, rate: 2, playing: false))
    }

    func testSimultaneousLeadAndBackingVocalsRemainVisible() {
        let timeline = LyricTimeline(lines: [
            LyricLine(start: 1, end: 4, text: "Lead", words: [.init(text: "Lead", start: 1.1, end: 3.9)]),
            LyricLine(start: 1, end: 3, text: "(ohh)", words: [.init(text: "(ohh)", start: 1.2, end: 2.9)])
        ])
        let frame = LyricVocalFrame(entries: timeline.displayed(at: 2, duration: 10), elapsed: 2)
        XCTAssertTrue(timeline.hasConcurrentVocals)
        XCTAssertEqual(frame.rows.count, 2)
        XCTAssertEqual(frame.rows[0].words[0].start, 1.1)
        XCTAssertEqual(frame.rows[1].words[0].start, 1.2)
        XCTAssertTrue(frame.rows[1].isBackground)
        XCTAssertEqual(timeline.active(at: 3.5, duration: 10).count, 1)
    }

    func testLongAdLibSurvivesSeveralNewLeadLines() {
        let timeline = LyricTimeline(lines: [
            LyricLine(start: 0, end: 5, text: "(ohh)"),
            LyricLine(start: 1, end: 2, text: "first"),
            LyricLine(start: 2, end: 3, text: "second"),
            LyricLine(start: 3, end: 4, text: "third")
        ])
        let frame = LyricVocalFrame(entries: timeline.displayed(at: 3.5, duration: 10), elapsed: 3.5)
        XCTAssertEqual(frame.rows.map { $0.words.map(\.text).joined(separator: " ") }, ["third", "(ohh)"])
        XCTAssertTrue(LyricWordPhase(word: frame.rows[1].words[0], elapsed: 3.5).isActive)
    }

    func testInlineParenthesesRetainIndependentWordTiming() {
        let words = [LyricLine.Word(text: "दिल", start: 1, end: 2),
                     .init(text: "(ohh", start: 1.5, end: 2.5),
                     .init(text: "yeah)", start: 2.5, end: 3),
                     .init(text: "तेरा", start: 3, end: 4)]
        let line = LyricLine(start: 1, end: 4, text: "दिल (ohh yeah) तेरा", words: words)
        let split = line.resolvedWords(until: 4)
        XCTAssertEqual(split.map(\.isBackground), [false, true, true, false])
        XCTAssertEqual(split.map(\.start), words.map(\.start))
        XCTAssertEqual(split.map(\.end), words.map(\.end))
        let frame = LyricVocalFrame(entries: LyricTimeline(lines: [line]).displayed(at: 1.75, duration: 10), elapsed: 1.75)
        XCTAssertTrue(LyricWordPhase(word: frame.rows[0].words[0], elapsed: 1.75).isActive)
        XCTAssertTrue(LyricWordPhase(word: frame.rows[1].words[0], elapsed: 1.75).isActive)
    }

    func testRichWordEndIsNotTruncatedByNextLine() {
        let timeline = LyricTimeline(lines: [
            LyricLine(start: 1, end: nil, text: "long", words: [.init(text: "long", start: 1, end: 4)]),
            LyricLine(start: 2, end: 3, text: "next")
        ])
        XCTAssertEqual(timeline.active(at: 2.5, duration: 10).count, 2)
        XCTAssertEqual(timeline.active(at: 3.5, duration: 10).count, 1)
        XCTAssertTrue(timeline.active(at: 4, duration: 10).isEmpty)
    }

    func testReadableLineSurvivesShortAndLongSilenceAndEmptyMarkers() {
        let timeline = LyricTimeline(lines: [
            LyricLine(start: 2, end: 3, text: "first"),
            LyricLine(start: 3, end: nil, text: ""),
            LyricLine(start: 3.5, end: 4, text: "second"),
            LyricLine(start: 10, end: 11, text: "third")
        ])
        for time in [0.0, 2.9, 3.0, 3.25, 3.499] {
            XCTAssertEqual(timeline.displayed(at: time, duration: 12).first?.line.text, "first")
        }
        for time in [3.5, 4, 9.99] {
            XCTAssertEqual(timeline.displayed(at: time, duration: 12).first?.line.text, "second")
        }
        XCTAssertEqual(timeline.displayed(at: 12, duration: 12).first?.line.text, "third")
        XCTAssertTrue(timeline.active(at: 3.25, duration: 12).isEmpty)
        let held = timeline.displayed(at: 9, duration: 12)[0]
        XCTAssertEqual(LyricWordPhase(word: held.words[0], elapsed: 9).illumination, 0)
        XCTAssertEqual(LyricWordPhase(word: timeline.entries[0].words[0], elapsed: 0).illumination, 0)
    }

    func testSequentialAdLibStaysInlineWithoutExtraRow() {
        let line = LyricLine(start: 1, end: 4, text: "coming home (ow)", words: [
            .init(text: "coming", start: 1, end: 2),
            .init(text: "home", start: 2, end: 3),
            .init(text: "(ow)", start: 3, end: 4)
        ])
        let timeline = LyricTimeline(lines: [line])
        for time in [0.0, 1.5, 3.5, 5] {
            let frame = LyricVocalFrame(entries: timeline.displayed(at: time, duration: 10), elapsed: time)
            XCTAssertEqual(frame.rows.count, 1)
            XCTAssertEqual(frame.rows[0].words.map(\.text), ["coming", "home", "(ow)"])
        }
    }

    func testOverlappingAdLibOnlyAppearsInsideItsOwnWindow() {
        let timeline = LyricTimeline(lines: [LyricLine(start: 1, end: 5, text: "lead (ow) again", words: [
            .init(text: "lead", start: 1, end: 3),
            .init(text: "(ow)", start: 2, end: 2.5),
            .init(text: "again", start: 3, end: 5)
        ])])
        for time in [0.0, 1.5, 2.5, 4, 6] {
            let frame = LyricVocalFrame(entries: timeline.displayed(at: time, duration: 10), elapsed: time)
            XCTAssertEqual(frame.rows.count, 1)
        }
        let frame = LyricVocalFrame(entries: timeline.displayed(at: 2.25, duration: 10), elapsed: 2.25)
        XCTAssertEqual(frame.rows.count, 2)
        XCTAssertEqual(frame.rows[1].words.map(\.text), ["(ow)"])
    }

    func testSeparateAdLibsNeverShowOneAnotherEarly() {
        let timeline = LyricTimeline(lines: [LyricLine(start: 1, end: 5, text: "lead (oh) again (yeah)", words: [
            .init(text: "lead", start: 1, end: 3),
            .init(text: "(oh)", start: 2, end: 2.5),
            .init(text: "again", start: 3, end: 5),
            .init(text: "(yeah)", start: 4, end: 4.5)
        ])])
        let first = LyricVocalFrame(entries: timeline.displayed(at: 2.25, duration: 10), elapsed: 2.25)
        let next = LyricVocalFrame(entries: timeline.displayed(at: 4.25, duration: 10), elapsed: 4.25)
        XCTAssertEqual(first.rows[1].words.map(\.text), ["(oh)"])
        XCTAssertEqual(next.rows[1].words.map(\.text), ["(yeah)"])
    }

    func testHeldVowelHasSoftAttackAndReleaseWithoutExtendingTiming() {
        let word = LyricLine.Word(text: "home", start: 1, end: 2)
        let attack = LyricWordPhase(word: word, elapsed: 1.04)
        let release = LyricWordPhase(word: word, elapsed: 1.94)
        XCTAssertGreaterThan(attack.illumination, 0)
        XCTAssertLessThan(attack.illumination, 0.5)
        XCTAssertGreaterThan(release.illumination, 0)
        XCTAssertLessThan(release.illumination, 0.5)
        XCTAssertLessThan(attack.reflectionProgress, attack.progress)
        XCTAssertGreaterThan(release.reflectionProgress, release.progress)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 2).illumination, 0)
    }

    func testDisplaySelectionFollowsSeekAndNeverKeepsAnotherTrack() {
        let timeline = LyricTimeline(lines: [LyricLine(start: 1, end: 2, text: "first"),
                                             LyricLine(start: 5, end: 6, text: "next")])
        XCTAssertEqual(timeline.displayed(at: 9, duration: 10).first?.line.text, "next")
        XCTAssertEqual(timeline.displayed(at: 3, duration: 10).first?.line.text, "first")
        XCTAssertTrue(timeline.displayed(at: .nan, duration: 10).isEmpty)
        XCTAssertTrue(LyricTimeline(lines: []).displayed(at: 3, duration: 10).isEmpty)
        XCTAssertEqual(LyricTimeline(lines: [LyricLine(start: 5, end: 6, text: "new track")])
            .displayed(at: 0, duration: 10).first?.line.text, "new track")
    }

    func testFastReadingPagesKeepWholeWordsAndReuseMeasurements() {
        let words = ["I", "got", "all", "these", "words", "coming", "very", "fast", "tonight"].enumerated().map {
            LyricLine.Word(text: $0.element, start: Double($0.offset) * 0.1, end: Double($0.offset + 1) * 0.1)
        }
        let layout = LyricTextLayout.cached(words: words, romanize: false, pointSize: 13, width: 120)
        XCTAssertTrue(layout.pages.count > 1)
        XCTAssertEqual(layout.pages.flatMap { Array($0) }, Array(words.indices))
        for page in layout.pages {
            let measure = page.map { layout.widths[$0] }.reduce(0, +) + Double(page.count - 1) * layout.spacing
            XCTAssertTrue(measure <= 116)
        }
        XCTAssertTrue(layout === LyricTextLayout.cached(words: words, romanize: false, pointSize: 13, width: 120))
    }

    func testHinglishPreservesWordsFormattingAndMixedEnglish() {
        XCTAssertEqual(LyricsRomanizer.romanize("दिल,  love (प्यार)\nतेरा-मेरा"), "dil,  love (pyaar)\ntera-mera")
        XCTAssertEqual(LyricsRomanizer.romanize("तुझे मुझे साँसें ज़िंदगी ज्ञान"), "tujhe mujhe saansein zindagi gyaan")
        XCTAssertEqual(LyricsRomanizer.romanize("कंबल"), "kambal")
        XCTAssertEqual(LyricsRomanizer.romanize("Stay (ohh…)  tonight"), "Stay (ohh…)  tonight")
    }
}
