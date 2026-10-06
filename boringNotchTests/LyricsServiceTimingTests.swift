import XCTest
@testable import boringNotch

@MainActor
final class LyricsServiceTimingTests: XCTestCase {
    func testProviderCacheKeepsExactTimingAndHonorsGaps() async {
        let service = LyricsService.shared
        service.clearLyrics()
        let title = "Timing fixture \(UUID().uuidString)"
        let words = [LyricLine.Word(text: "one", start: 10.2, end: 10.6),
                     .init(text: "two", start: 11, end: 11.4)]
        service.setProviderLyrics([LyricLine(start: 10, end: 12, text: "one two", words: words)], title: title, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture", preferProvider: true)
        XCTAssertEqual(service.timedLyrics[0].words, words)
        XCTAssertNil(service.timedLine(at: 9.99))
        XCTAssertEqual(service.timedLine(at: 10)?.line.text, "one two")
        XCTAssertNil(service.timedLine(at: 12))
        service.setProviderLyrics([LyricLine(start: 10, end: nil, text: "one two")], title: title, artist: "Fixture")
        XCTAssertEqual(service.timedLyrics[0].words, words)
        service.clearLyrics()
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture")
        XCTAssertEqual(service.timedLyrics[0].words, words)
        service.clearLyrics()
    }

    func testCachedRowsFollowAdLibBoundariesGapsAndBackwardSeek() async {
        let service = LyricsService.shared
        service.clearLyrics()
        let title = "Frame fixture \(UUID().uuidString)"
        let lines = [LyricLine(start: 1, end: 5, text: "lead (oh) again (yeah)", words: [
            .init(text: "lead", start: 1, end: 3),
            .init(text: "(oh)", start: 2, end: 2.5),
            .init(text: "again", start: 3, end: 5),
            .init(text: "(yeah)", start: 4, end: 4.5)
        ]), LyricLine(start: 6, end: 7, text: "next")]
        service.setProviderLyrics(lines, title: title, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture")
        let reference = LyricTimeline(lines: lines)
        for elapsed in [0.0, 1.5, 2, 2.001, 2.25, 2.499, 2.5, 3, 4, 4.499, 4.5, 6, 7, 8, 2.25, 0] {
            let actual = service.vocalFrame(at: elapsed, duration: 8)
            let expected = LyricVocalFrame(entries: reference.displayed(at: elapsed, duration: 8), elapsed: elapsed)
            XCTAssertEqual(actual.rows.map(\.words), expected.rows.map(\.words), "At \(elapsed)")
        }
        XCTAssertTrue(service.vocalFrame(at: .nan, duration: 8).rows.isEmpty)
        let oldID = service.vocalFrame(at: 2.25, duration: 8).rows[0].id
        service.clearLyrics()
        XCTAssertTrue(service.vocalFrame(at: 2.25, duration: 8).rows.isEmpty)
        let otherTitle = "New frame fixture \(UUID().uuidString)"
        service.setProviderLyrics(lines, title: otherTitle, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: otherTitle, artist: "Fixture")
        XCTAssertNotEqual(service.vocalFrame(at: 2.25, duration: 8).rows[0].id, oldID)
        service.clearLyrics()
    }

    func testLineOnlyScheduleStopsWhenPausedAndHonorsPlaybackSpeed() async {
        let service = LyricsService.shared
        service.clearLyrics()
        let title = "Schedule fixture \(UUID().uuidString)"
        service.setProviderLyrics([LyricLine(start: 10, end: 12, text: "one two")], title: title, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture")
        XCTAssertFalse(service.hasWordTimings)
        XCTAssertFalse(service.vocalFrame(at: 10, duration: 15).rows[0].hasExactTiming)
        let date = Date()
        XCTAssertEqual(service.displayDates(anchorPosition: 0, anchorDate: date, rate: 1, playing: false).count, 1)
        XCTAssertEqual(service.displayDates(anchorPosition: 0, anchorDate: date, rate: 0, playing: true).count, 1)
        let dates = service.displayDates(anchorPosition: 0, anchorDate: date, rate: 2, playing: true)
        XCTAssertEqual(dates[1].timeIntervalSince(date), 5.000001, accuracy: 0.000001)
        service.clearLyrics()
    }

    func testMalformedAlignmentFallsBackWithoutDroppingWords() async {
        let service = LyricsService.shared
        let title = "Invalid fixture \(UUID().uuidString)"
        service.setProviderLyrics([LyricLine(start: 1, end: 3, text: "one two", words: [
            .init(text: "one", start: 1, end: 2), .init(text: "two", start: .nan, end: 3)
        ])], title: title, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture")
        XCTAssertTrue(service.timedLyrics[0].words.isEmpty)
        XCTAssertEqual(service.timedLyrics[0].resolvedWords(until: 3).map(\.text), ["one", "two"])
        service.clearLyrics()
    }

    func testPlainProviderLyricsHaveNoInventedAlignment() async {
        let service = LyricsService.shared
        let title = "Plain fixture \(UUID().uuidString)"
        service.setProviderLyrics([], plainLyrics: "First line\nSecond line", title: title, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture")
        XCTAssertEqual(service.currentLyrics, "First line\nSecond line")
        XCTAssertTrue(service.timedLyrics.isEmpty)
        service.clearLyrics()
    }

    func testExactHighlightScheduleIncludesBothEndsAndSkipsSilentFrames() async {
        let service = LyricsService.shared
        service.clearLyrics()
        let title = "Word schedule fixture \(UUID().uuidString)"
        let words = [LyricLine.Word(text: "one", start: 10.125, end: 10.175),
                     .init(text: "two", start: 11, end: 11.5)]
        service.setProviderLyrics([LyricLine(start: 10, end: 12, text: "one two", words: words)], title: title, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture")
        let anchor = Date()
        let dates = service.displayDates(anchorPosition: 0, anchorDate: anchor, rate: 2, playing: true)
        // Initial frame plus line/word boundaries; silence needs no refresh loop.
        XCTAssertEqual(dates.count, 7)
        for (date, stamp) in zip(dates.dropFirst(), [10.0, 10.125, 10.175, 11, 11.5, 12]) {
            let elapsed = date.timeIntervalSince(anchor) * 2
            XCTAssertTrue(elapsed >= stamp)
            XCTAssertEqual(elapsed, stamp, accuracy: 0.000003)
        }
        let firstEnd = dates[3].timeIntervalSince(anchor) * 2
        XCTAssertFalse(LyricWordPhase(word: words[0], elapsed: firstEnd).isActive)
        XCTAssertEqual(service.displayDates(anchorPosition: 10.15, anchorDate: anchor, rate: 2, playing: false).count, 1)
        service.clearLyrics()
    }

    func testSharedRowClockAvoidsRebuildingSongViewForEveryRapWord() async {
        let service = LyricsService.shared
        service.clearLyrics()
        let title = "Rapid schedule fixture \(UUID().uuidString)"
        let words = (0..<20).map { LyricLine.Word(text: "rap", start: 10 + Double($0) * 0.05,
            end: 10 + Double($0 + 1) * 0.05) }
        service.setProviderLyrics([LyricLine(start: 10, end: 11, text: words.map(\.text).joined(separator: " "), words: words)],
            title: title, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture")
        let anchor = Date()
        let rowDates = service.displayDates(anchorPosition: 0, anchorDate: anchor, rate: 1, playing: true, wordBoundaries: false)
        XCTAssertEqual(rowDates.count, 3) // initial, onset, end; one local animation clock
        XCTAssertEqual(service.displayDates(anchorPosition: 0, anchorDate: anchor, rate: 1, playing: true).count, 22)
        service.clearLyrics()
    }

    func testSharedRowScheduleRestartsAfterLeadAndBackingSilence() async {
        let service = LyricsService.shared
        service.clearLyrics()
        let title = "Vocal gap fixture \(UUID().uuidString)"
        service.setProviderLyrics([LyricLine(start: 10, end: 15, text: "lead (oh yeah) again", words: [
            .init(text: "lead", start: 10, end: 15),
            .init(text: "(oh", start: 11, end: 12),
            .init(text: "yeah)", start: 13, end: 14),
            .init(text: "again", start: 15, end: 16)
        ])], title: title, artist: "Fixture")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture")
        let anchor = Date()
        let dates = service.displayDates(anchorPosition: 0, anchorDate: anchor, rate: 1, playing: true, wordBoundaries: false)
        for stamp in [11.0, 12, 13, 14, 16] {
            XCTAssertTrue(dates.contains { abs($0.timeIntervalSince(anchor) - stamp) < 0.00001 })
        }
        service.clearLyrics()
    }
}
