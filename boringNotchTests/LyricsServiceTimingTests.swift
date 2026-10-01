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
}
