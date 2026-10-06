import XCTest
@testable import boringNotch

final class LyricsPrecisionTests: XCTestCase {
    func testMajboorLineOnlyLyricsHighlightIndividualWords() {
        let lines = LyricLine.parseLRC("[00:13.44] Sachhi Tu Ya Main Jhoota?\n[00:15.62] Hun Ki Karna Haan Haan\n[00:18.87]")
        assertEstimatedWordHighlights(lines)
    }

    func testBandaKaamKaMixedScriptLyricsHighlightIndividualWords() {
        let lines = LyricLine.parseLRC("[00:03.09] Hmm, सीधा-सीधा रास्ता था\n[00:08.46]")
        assertEstimatedWordHighlights(lines)
    }

    private func assertEstimatedWordHighlights(_ lines: [LyricLine]) {
        let timeline = LyricTimeline(lines: lines)
        XCTAssertFalse(timeline.hasWordTimings)
        for entry in timeline.entries where !entry.words.isEmpty {
            let row = entry.vocalRows.primary!
            XCTAssertFalse(row.hasExactTiming)
            XCTAssertTrue(row.hasEstimatedTiming)
            XCTAssertTrue(row.highlightsWords)
            XCTAssertEqual(row.words.map(\.text), entry.line.text.split(whereSeparator: \.isWhitespace).map(String.init))
            XCTAssertEqual(row.start, entry.line.start)
            XCTAssertEqual(row.end, entry.end, accuracy: 0.000001)
            for (index, word) in row.words.enumerated() {
                let midpoint = (word.start + word.end) / 2
                XCTAssertEqual(row.anchor(at: midpoint), index)
                XCTAssertEqual(row.words.filter { LyricWordPhase(word: $0, elapsed: midpoint).isActive }.count, 1)
                let phase = LyricWordPhase(word: word, elapsed: midpoint)
                XCTAssertEqual(phase.visibleSheenOpacity, 1)
                XCTAssertTrue(phase.phraseInkOpacity > LyricWordPhase(word: word, elapsed: row.start - 0.01).inkOpacity)
            }
            XCTAssertFalse(row.isActive(at: row.end))
        }
    }

    func testPhoneticFallbackUsesTheSameClockForHindiAndRomanizedDisplay() {
        let native = LyricLine(start: 1, end: 5, text: "तेरा मेरा प्यार")
        let latin = LyricLine(start: 1, end: 5, text: LyricsRomanizer.romanize(native.text))
        let nativeWords = LyricTimeline(lines: [native]).entries[0].words
        let latinWords = LyricTimeline(lines: [latin]).entries[0].words
        XCTAssertEqual(nativeWords.map(\.start), latinWords.map(\.start))
        XCTAssertEqual(nativeWords.map(\.end), latinWords.map(\.end))
        XCTAssertTrue(LyricPhoneticTiming.weight(of: "pyaar") < LyricPhoneticTiming.weight(of: "samajh"))
        XCTAssertEqual(LyricPhoneticTiming.weight(of: "Tu.."), LyricPhoneticTiming.weight(of: "Tu") + 1)
    }

    func testEnglishLineFallbackAndExactHindiTimingArePreserved() {
        let english = LyricLine(start: 1, end: 5, text: "Stay with me tonight")
        let row = LyricTimeline(lines: [english]).entries[0].vocalRows.primary!
        XCTAssertFalse(row.highlightsWords)
        XCTAssertEqual(row.words, english.resolvedWords(until: 5))
        let exact = LyricLine(start: 1, end: 5, text: "तेरा प्यार", words: [
            .init(text: "तेरा", start: 1.125, end: 2.25), .init(text: "प्यार", start: 3.5, end: 4.875)
        ])
        let exactRow = LyricTimeline(lines: [exact]).entries[0].vocalRows.primary!
        XCTAssertTrue(exactRow.hasExactTiming)
        XCTAssertFalse(exactRow.hasEstimatedTiming)
        XCTAssertEqual(exactRow.words, exact.words)
        XCTAssertFalse(exactRow.isActive(at: 3))
    }

    func testHighlightBoundariesUseMillisecondsWithoutAnimationLag() {
        let word = LyricLine.Word(text: "दिल", start: 10.125, end: 10.425)
        XCTAssertFalse(LyricWordPhase(word: word, elapsed: 10.124).isActive)
        XCTAssertTrue(LyricWordPhase(word: word, elapsed: 10.125).isActive)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 10.275).progress, 0.5, accuracy: 0.000001)
        XCTAssertTrue(LyricWordPhase(word: word, elapsed: 10.424999).isActive)
        XCTAssertFalse(LyricWordPhase(word: word, elapsed: 10.425).isActive)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 10.425).progress, 1)
    }

    func testFastWordsAreActiveForTheirEntireWindow() {
        let first = LyricLine.Word(text: "one", start: 1, end: 1.05)
        let next = LyricLine.Word(text: "two", start: 1.05, end: 1.10)
        XCTAssertTrue(LyricWordPhase(word: first, elapsed: 1.025).isActive)
        XCTAssertFalse(LyricWordPhase(word: first, elapsed: 1.05).isActive)
        XCTAssertTrue(LyricWordPhase(word: next, elapsed: 1.05).isActive)
        XCTAssertTrue(LyricWordPhase(word: next, elapsed: 1.075).isActive)
    }

    func testPauseAndSeekFramesAreDeterministic() {
        let word = LyricLine.Word(text: "ohh", start: 3, end: 5)
        let before = LyricWordPhase(word: word, elapsed: 3.875)
        _ = LyricWordPhase(word: word, elapsed: 12)
        let afterSeek = LyricWordPhase(word: word, elapsed: 3.875)
        XCTAssertEqual(before.progress, afterSeek.progress)
        XCTAssertEqual(before.isActive, afterSeek.isActive)
        XCTAssertFalse(LyricWordPhase(word: word, elapsed: .nan).isActive)
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

    func testClockJitterIsIgnoredAndPlaybackRateIsRespected() {
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(LyricPlaybackClock.needsCorrection(position: 11.003, sampleDate: date.addingTimeInterval(1),
            anchorPosition: 10, anchorDate: date, rate: 1, playing: true))
        XCTAssertTrue(LyricPlaybackClock.needsCorrection(position: 11.2, sampleDate: date.addingTimeInterval(1),
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
        XCTAssertFalse(LyricWordPhase(word: held.words[0], elapsed: 9).isActive)
        XCTAssertFalse(LyricWordPhase(word: timeline.entries[0].words[0], elapsed: 0).isActive)
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

    func testHeldWordNeverFadesBeforeItsEndAndGapsHaveNoActiveWord() {
        let words = [LyricLine.Word(text: "home", start: 1, end: 3),
                     .init(text: "again", start: 4, end: 5)]
        for elapsed in [1.0, 1.000001, 1.04, 2, 2.94, 2.999999] {
            XCTAssertTrue(LyricWordPhase(word: words[0], elapsed: elapsed).isActive)
        }
        for elapsed in [0.0, 3, 3.5, 3.999999, 5, 6] {
            XCTAssertFalse(words.contains { LyricWordPhase(word: $0, elapsed: elapsed).isActive })
        }
    }

    func testMalformedTimingNeverCreatesHighlightOrCompletion() {
        for word in [LyricLine.Word(text: "bad", start: .nan, end: 1),
                     .init(text: "bad", start: 1, end: .infinity),
                     .init(text: "bad", start: 2, end: 1),
                     .init(text: "bad", start: 1, end: 1)] {
            let phase = LyricWordPhase(word: word, elapsed: 3)
            XCTAssertFalse(phase.isActive)
            XCTAssertEqual(phase.progress, 0)
        }
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

    func testRowLayoutIdentityIncludesTrackAndConfiguration() {
        let line = LyricLine(start: 1, end: 5, text: "same text")
        let first = LyricTimeline(lines: [line])
        let second = LyricTimeline(lines: [line])
        let row = LyricVocalFrame(entries: first.displayed(at: 2, duration: 6), elapsed: 2).rows[0]
        let another = LyricVocalFrame(entries: second.displayed(at: 2, duration: 6), elapsed: 2).rows[0]
        XCTAssertNotEqual(row.id, another.id)
        let layout = LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: false, pointSize: 13, width: 120)
        XCTAssertTrue(layout === LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: false, pointSize: 13, width: 120))
        XCTAssertFalse(layout === LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: false, pointSize: 13, width: 80))
        XCTAssertFalse(layout === LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: true, pointSize: 13, width: 120))
        XCTAssertEqual(layout.pageForWord.count, row.words.count)
    }

    func testPreparedAnchorPreservesSourceOrderForOverlappingWords() {
        let words: [LyricLine.Word] = [
            .init(text: "first", start: 1, end: 2),
            .init(text: "later", start: 4, end: 5),
            .init(text: "overlap", start: 2, end: 6),
            .init(text: "same stamp", start: 2, end: 3)
        ]
        let row = LyricVocalFrame.Row(id: "fixture", words: words, isBackground: false, hasExactTiming: true)
        for elapsed in [0.0, 1, 1.999, 2, 3, 4, 5, 7, 2, .nan] {
            XCTAssertEqual(row.anchor(at: elapsed), words.lastIndex { elapsed >= $0.start } ?? 0)
        }
    }

    func testFrameBucketsDoNotChangeAcrossContiguousWords() {
        let timeline = LyricTimeline(lines: [LyricLine(start: 1, end: 4, text: "one two three", words: [
            .init(text: "one", start: 1, end: 2), .init(text: "two", start: 2, end: 3),
            .init(text: "three", start: 3, end: 4)
        ])])
        XCTAssertEqual(timeline.displayBucket(at: 1.5), timeline.displayBucket(at: 3.5))
        XCTAssertNotEqual(timeline.displayBucket(at: 3.5), timeline.displayBucket(at: 4))
    }

    func testHinglishPreservesWordsFormattingAndMixedEnglish() {
        XCTAssertEqual(LyricsRomanizer.romanize("दिल,  love (प्यार)\nतेरा-मेरा"), "dil,  love (pyaar)\ntera-mera")
        XCTAssertEqual(LyricsRomanizer.romanize("तुझे मुझे साँसें ज़िंदगी ज्ञान"), "tujhe mujhe saansein zindagi gyaan")
        XCTAssertEqual(LyricsRomanizer.romanize("कंबल"), "kambal")
        XCTAssertEqual(LyricsRomanizer.romanize("Stay (ohh…)  tonight"), "Stay (ohh…)  tonight")
    }

    func testRomanizedLayoutKeepsSourceWordAlignmentAndFitsExpandedTokens() {
        let words = [LyricLine.Word(text: "தமிழ்", start: 1.125, end: 1.625),
                     .init(text: "안녕", start: 2, end: 3),
                     .init(text: "tonight", start: 3, end: 4)]
        let layout = LyricTextLayout.cached(words: words, romanize: true, pointSize: 13, width: 95)
        XCTAssertEqual(layout.text, ["tamiḻ", "annyeong", "tonight"])
        XCTAssertEqual(layout.text.count, words.count)
        XCTAssertEqual(layout.pages.flatMap { Array($0) }, Array(words.indices))
        for page in layout.pages {
            XCTAssertTrue(page.map { layout.widths[$0] }.reduce(0, +) + Double(page.count - 1) * layout.spacing <= 91.01)
        }
        XCTAssertTrue(LyricWordPhase(word: words[0], elapsed: 1.125).isActive)
        XCTAssertFalse(LyricWordPhase(word: words[0], elapsed: 1.625).isActive)
    }

    func testOversizedTokenStaysCompleteAndFitsItsPage() {
        let word = LyricLine.Word(text: "extraordinarily", start: 1, end: 2)
        let layout = LyricTextLayout.cached(words: [word], romanize: false, pointSize: 13, width: 65)
        XCTAssertEqual(layout.text, [word.text])
        XCTAssertLessThan(layout.pointSizes[0], 13)
        XCTAssertTrue(layout.widths[0] <= 61.01)
        XCTAssertEqual(layout.pages, [0..<1])
    }

    func testSmallClockLagIsCorrectedInBothDirections() {
        let date = Date(timeIntervalSince1970: 100)
        for position in [10.92, 11.03, 11.08] {
            XCTAssertTrue(LyricPlaybackClock.needsCorrection(position: position, sampleDate: date.addingTimeInterval(1),
                anchorPosition: 10, anchorDate: date, rate: 1, playing: true))
        }
    }

    func testQueuedBrowserSampleProjectsToRenderTimeWithoutTransportLag() {
        let received = Date(timeIntervalSince1970: 1234.078)
        let sampled = LyricPlaybackClock.sampleDate(milliseconds: 1234025, receivedAt: received)
        let position = LyricPlaybackClock.position(anchorPosition: 10.125, anchorDate: sampled,
            at: received.addingTimeInterval(0.04), rate: 1, playing: true, duration: 100)
        XCTAssertEqual(position, 10.218, accuracy: 0.000001)
    }

    func testReconnectKeepsOldValidAnchorInsteadOfIntroducingSecondsOfLag() {
        let received = Date(timeIntervalSince1970: 1234.425)
        let sample = LyricPlaybackClock.sampleDate(milliseconds: 1231025, receivedAt: received)
        XCTAssertEqual(sample.timeIntervalSince1970, 1231.025, accuracy: 0.000001)
        XCTAssertEqual(LyricPlaybackClock.position(anchorPosition: 10.125, anchorDate: sample,
            at: received, rate: 1, playing: true, duration: 100), 13.525, accuracy: 0.000001)
    }

    func testClockProjectionFreezesOnPauseAndBufferingAndRespectsSpeed() {
        let sample = Date(timeIntervalSince1970: 100)
        let render = sample.addingTimeInterval(0.125)
        XCTAssertEqual(LyricPlaybackClock.position(anchorPosition: 10, anchorDate: sample, at: render,
            rate: 2, playing: true, duration: 100), 10.25)
        XCTAssertEqual(LyricPlaybackClock.position(anchorPosition: 10, anchorDate: sample, at: render,
            rate: 2, playing: false, duration: 100), 10)
        XCTAssertEqual(LyricPlaybackClock.position(anchorPosition: 10, anchorDate: sample, at: render,
            rate: 0, playing: true, duration: 100), 10)
    }

    func testLightIsAlreadyInsideTheTextAtTheExactWordStart() {
        let word = LyricLine.Word(text: "held", start: 10, end: 14)
        let onset = LyricWordPhase(word: word, elapsed: 10)
        XCTAssertTrue(onset.isActive)
        XCTAssertEqual(onset.progress, 0)
        XCTAssertEqual(onset.revealEdge, 0.18)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 12).revealEdge, 0.68, accuracy: 0.000001)
        XCTAssertFalse(LyricWordPhase(word: word, elapsed: 9.999).isActive)
    }

    func testRapidWordsNeverFlashBackToDimAfterBeingSung() {
        let words = (0..<20).map { LyricLine.Word(text: "rap", start: Double($0) * 0.05, end: Double($0 + 1) * 0.05) }
        for word in words {
            var previousOpacity = 0.0
            for frame in 0...120 {
                let phase = LyricWordPhase(word: word, elapsed: Double(frame) / 60)
                XCTAssertTrue(phase.inkOpacity >= previousOpacity)
                previousOpacity = phase.inkOpacity
            }
            XCTAssertEqual(previousOpacity, 1)
        }
    }

    func testDenseVocalsGetDisplaySamplesWithoutSpeedingUpHeldNotes() {
        let rap = LyricVocalFrame.Row(id: "rap", words: [.init(text: "quick", start: 0, end: 0.05)],
            isBackground: false, hasExactTiming: true)
        let held = LyricVocalFrame.Row(id: "held", words: [.init(text: "ohh", start: 0, end: 2)],
            isBackground: false, hasExactTiming: true)
        let spoken = LyricVocalFrame.Row(id: "spoken", words: [.init(text: "word", start: 0, end: 0.4)],
            isBackground: false, hasExactTiming: true)
        XCTAssertEqual(rap.animationInterval(rate: 1), 1.0 / 60)
        XCTAssertEqual(held.animationInterval(rate: 1), 1.0 / 30)
        XCTAssertEqual(spoken.animationInterval(rate: 1), 1.0 / 30)
        XCTAssertEqual(spoken.animationInterval(rate: 2), 1.0 / 60)
    }

    func testJunoonLineOnlyPhraseIsFullyLitAtItsActualOnset() {
        let lines = LyricLine.parseLRC("[00:13.59] Ki mai khwaab vekhya yaara\n[00:17.20]")
        let timeline = LyricTimeline(lines: lines)
        let row = LyricVocalFrame(entries: timeline.displayed(at: 13.59, duration: 191), elapsed: 13.59).rows[0]
        XCTAssertFalse(row.hasExactTiming)
        let phrase = LyricLine.Word(text: row.text, start: row.start, end: row.end)
        XCTAssertEqual(LyricWordPhase(word: phrase, elapsed: 13.589).phraseInkOpacity, 0.65)
        for time in [13.59, 13.591, 14, 16.999] {
            XCTAssertEqual(LyricWordPhase(word: phrase, elapsed: time).phraseInkOpacity, 0.9)
        }
        // Switching romanization cannot change the source clock or cadence.
        _ = LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: true, pointSize: 13, width: 420)
        XCTAssertEqual(row.start, 13.59)
        XCTAssertEqual(row.end, 17.20, accuracy: 0.000001)
        XCTAssertEqual(row.animationInterval(rate: 1), 1.0 / 30)
    }

    func testLineSheenEntersAndExitsContinuouslyWithoutEdgeFlash() {
        let word = LyricLine.Word(text: "phrase", start: 0, end: 4)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 0).visibleSheenOpacity, 0.9)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 2).visibleSheenOpacity, 1)
        XCTAssertEqual(LyricWordPhase(word: word, elapsed: 4).visibleSheenOpacity, 0.9)
        var previous = 0.9
        for frame in 0...240 {
            let opacity = LyricWordPhase(word: word, elapsed: Double(frame) / 60).visibleSheenOpacity
            XCTAssertTrue(abs(opacity - previous) <= 0.003)
            previous = opacity
        }
    }
}
