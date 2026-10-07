import XCTest
import Defaults
@testable import boringNotch

@MainActor
final class SpicyLyricsTests: XCTestCase {
    private func payload(_ content: [[String: Any]], type: String = "Syllable") throws -> SpicyLyricsPayload {
        let data = try JSONSerialization.data(withJSONObject: ["Status": 200, "Body": [
            "Type": type, "source": "apple_music", "Content": content
        ]])
        return try XCTUnwrap(SpicyLyricsPayload.parse(data))
    }

    func testSyllablesMergeIntoWordsWithoutLosingGapsOrText() throws {
        let parsed = try payload([["Type": "Vocal", "Lead": ["StartTime": 10.1, "EndTime": 13.4, "Syllables": [
            ["Text": "बे", "StartTime": 10.1, "EndTime": 10.5, "IsPartOfWord": true],
            ["Text": "हतरीन", "StartTime": 10.5, "EndTime": 11.2, "IsPartOfWord": false],
            ["Text": "गीत", "StartTime": 12.8, "EndTime": 13.4, "IsPartOfWord": false]
        ]]]])
        XCTAssertEqual(parsed.plain, "बेहतरीन गीत")
        XCTAssertEqual(parsed.lines[0].words.map(\.text), ["बेहतरीन", "गीत"])
        XCTAssertEqual(parsed.lines[0].words.map(\.start), [10.1, 12.8])
        XCTAssertEqual(parsed.lines[0].words.map(\.end), [11.2, 13.4])
        XCTAssertEqual(parsed.attribution.provider, "Apple Music")
        XCTAssertFalse(LyricTimeline(lines: parsed.lines).entries[0].vocalRows.primary!.isActive(at: 12))
    }

    func testBackingVocalsKeepTheirOwnAbsoluteTimings() throws {
        let parsed = try payload([["Type": "Vocal", "Lead": ["Text": "lead", "StartTime": 1, "EndTime": 4],
            "Background": [["StartTime": 2, "EndTime": 3, "Syllables": [
                ["Text": "echo", "StartTime": 2, "EndTime": 3, "IsPartOfWord": false]
            ]]]]])
        XCTAssertEqual(parsed.lines.count, 2)
        XCTAssertTrue(parsed.lines[1].isBackground)
        XCTAssertTrue(parsed.lines[1].words[0].isBackground)
        XCTAssertEqual(parsed.lines[1].words[0].start, 2)
        XCTAssertEqual(parsed.plain, "lead\necho")
    }

    func testMalformedWordTimesKeepTextAndFallBackToLineTiming() throws {
        let parsed = try payload([["Lead": ["StartTime": 1, "EndTime": 4, "Syllables": [
            ["Text": "one", "StartTime": 1, "EndTime": 2],
            ["Text": "two", "StartTime": 3, "EndTime": 2]
        ]]]])
        XCTAssertEqual(parsed.plain, "one two")
        XCTAssertTrue(parsed.lines[0].words.isEmpty)
        XCTAssertEqual(parsed.lines[0].end, 4)
    }

    func testStaticAndLineResponsesDoNotInventWordTimes() throws {
        let rows: [[String: Any]] = [["Type": "Vocal", "Text": "A whole phrase", "StartTime": 1, "EndTime": 3]]
        let line = try payload(rows, type: "Line")
        XCTAssertEqual(line.precision, 1)
        XCTAssertTrue(line.lines[0].words.isEmpty)
        let plain = try payload(rows, type: "Static")
        XCTAssertEqual(plain.plain, "A whole phrase")
        XCTAssertTrue(plain.lines.isEmpty)
    }

    func testCacheRoundTripRetainsExactWordsAndSourceCredit() throws {
        let parsed = try payload([["Lead": ["StartTime": 1, "EndTime": 2, "Syllables": [
            ["Text": "word", "StartTime": 1, "EndTime": 2]
        ]]]])
        let decoded = try JSONDecoder().decode(SpicyLyricsPayload.self, from: JSONEncoder().encode(parsed))
        XCTAssertEqual(decoded.lines, parsed.lines)
        XCTAssertEqual(decoded.attribution, parsed.attribution)
        XCTAssertEqual(decoded.plain, parsed.plain)
    }

    func testSpicyTextAndTimingSurviveLateOctaveResponse() async {
        let service = LyricsService.shared
        service.clearLyrics()
        let title = "Spicy priority \(UUID())"
        let line = LyricLine(start: 1, end: 3, text: "provider text", words: [
            .init(text: "provider", start: 1, end: 1.5), .init(text: "text", start: 2, end: 3)
        ])
        let attribution = LyricAttribution(source: "apple_music", upload: nil)
        service.setProviderLyrics([line], plainLyrics: "provider text", title: title, artist: "Fixture", attribution: attribution)
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture", useEnhancedLyrics: true)
        service.setProviderLyrics([.init(start: 1, end: 3, text: "older text", words: line.words)], title: title, artist: "Fixture")
        XCTAssertEqual(service.currentLyrics, "provider text")
        XCTAssertEqual(service.attribution, attribution)
        XCTAssertEqual(service.timedLyrics, [line])
        service.clearLyrics()
        XCTAssertNil(service.attribution)
    }

    func testShimmerSettlesWithoutAnEndFlashAndRapStaysSteady() {
        let held = LyricLine.Word(text: "held", start: 1, end: 3)
        let onset = LyricWordPhase(word: held, elapsed: 1)
        XCTAssertGreaterThan(onset.shimmerOpacity(at: 0), 0.9)
        XCTAssertEqual(onset.shimmerOpacity(at: 1), 0.6)
        for position in [0.0, 0.25, 0.5, 0.75, 1] {
            XCTAssertEqual(LyricWordPhase(word: held, elapsed: 2.999).shimmerOpacity(at: position), 0.94, accuracy: 0.001)
            XCTAssertEqual(LyricWordPhase(word: held, elapsed: 3).shimmerOpacity(at: position), 0.94)
        }
        let rap = LyricLine.Word(text: "rap", start: 1, end: 1.08)
        XCTAssertEqual(LyricWordPhase(word: rap, elapsed: 1.04).shimmerOpacity(at: 0.5), 0.94)
        let beforeSeek = LyricWordPhase(word: held, elapsed: 1.08).shimmerOpacity(at: 0.25)
        _ = LyricWordPhase(word: held, elapsed: 20)
        XCTAssertEqual(LyricWordPhase(word: held, elapsed: 1.08).shimmerOpacity(at: 0.25), beforeSeek)
    }

    func testSingleRowHandoffIgnoresBackingVocalsAndNeverBlanks() {
        let lines = [
            LyricLine(start: 1, end: 5, text: "lead", words: [.init(text: "lead", start: 1, end: 5)]),
            LyricLine(start: 2, end: 3, text: "echo", words: [.init(text: "echo", start: 2, end: 3, isBackground: true)], isBackground: true),
            LyricLine(start: 4, end: 7, text: "next", words: [.init(text: "next", start: 4, end: 7)])
        ]
        let timeline = LyricTimeline(lines: lines)
        for time in [0.0, 1, 2, 2.5, 3, 3.999999] {
            XCTAssertEqual(timeline.displayedPrimary(at: time)?.vocalRows.primary?.text, "lead")
        }
        for time in [4.0, 4.000001, 5, 7, 10] {
            XCTAssertEqual(timeline.displayedPrimary(at: time)?.vocalRows.primary?.text, "next")
        }
        XCTAssertEqual(timeline.displayedPrimary(at: 2)?.vocalRows.primary?.text, "lead")
        XCTAssertNil(timeline.displayedPrimary(at: .nan))
        XCTAssertFalse(timeline.singleRowBoundaries.contains(2))
        XCTAssertFalse(timeline.singleRowBoundaries.contains(3))
        XCTAssertTrue(timeline.singleRowBoundaries.contains(4))
    }

    func testSingleRowScheduleRetainsVisibleWordGapsAndSkipsHiddenEchoes() {
        let lead = LyricLine(start: 1, end: 5, text: "one two", words: [
            .init(text: "one", start: 1, end: 2), .init(text: "two", start: 4, end: 5)
        ])
        let backing = LyricLine(start: 2.5, end: 3, text: "echo", words: [
            .init(text: "echo", start: 2.5, end: 3, isBackground: true)
        ], isBackground: true)
        let timeline = LyricTimeline(lines: [lead, backing])
        XCTAssertEqual(timeline.singleRowBoundaries, [1, 2, 4, 5])
        XCTAssertEqual(timeline.singleRowWordBoundaries, [1, 2, 4, 5])
        XCTAssertFalse(timeline.displayedPrimary(at: 3)?.vocalRows.primary?.isActive(at: 3) ?? true)
    }

    func testEnhancedToggleRestoresRegularLyricsAndRejectsLateEnhancedUpdates() async {
        let service = LyricsService.shared
        service.clearLyrics()
        let title = "Toggle fixture \(UUID())"
        let regular = LyricLine(start: 1, end: 3, text: "regular lyrics")
        let enhanced = LyricLine(start: 1.1, end: 2.9, text: "accurate words", words: [
            .init(text: "accurate", start: 1.1, end: 2), .init(text: "words", start: 2.2, end: 2.9)
        ])
        let attribution = LyricAttribution(source: "apple_music", upload: nil)
        service.setProviderLyrics([regular], title: title, artist: "Fixture")
        service.setProviderLyrics([enhanced], plainLyrics: "accurate words", title: title, artist: "Fixture", attribution: attribution)
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture", useEnhancedLyrics: true)
        XCTAssertEqual(service.timedLyrics, [enhanced])
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture", useEnhancedLyrics: false)
        XCTAssertEqual(service.timedLyrics, [regular])
        XCTAssertNil(service.attribution)
        service.setProviderLyrics([enhanced], plainLyrics: "accurate words", title: title, artist: "Fixture", attribution: attribution)
        XCTAssertEqual(service.currentLyrics, "regular lyrics")
        await service.fetchLyrics(bundleIdentifier: nil, title: title, artist: "Fixture", useEnhancedLyrics: true)
        XCTAssertEqual(service.currentLyrics, "accurate words")
        service.clearLyrics()
    }

    func testKeyFormatAcceptsOwnSecretOrClientKeysWithoutQueryInjection() {
        XCTAssertTrue(SpicyLyricsCredential.accepts("sl_sk_" + String(repeating: "a", count: 30)))
        XCTAssertTrue(SpicyLyricsCredential.accepts(" sl_pk_" + String(repeating: "b", count: 30) + "\n"))
        XCTAssertFalse(SpicyLyricsCredential.accepts("sl_sk_short"))
        XCTAssertFalse(SpicyLyricsCredential.accepts("not-a-key"))
        XCTAssertFalse(SpicyLyricsCredential.accepts("sl_sk_" + String(repeating: "a", count: 30) + "\nother"))
    }

    func testInvalidSettingsKeyDoesNotEnableFeature() {
        let enabled = Defaults[.enableEnhancedLyrics]
        let model = EnhancedLyricsSettingsModel()
        model.draftKey = "not-a-key"
        model.saveAndEnable()
        XCTAssertTrue(model.isError)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.hasSavedKey)
        XCTAssertTrue(model.message != nil)
        XCTAssertEqual(Defaults[.enableEnhancedLyrics], enabled)
    }

    func testClosingKeyEditorClearsItsDraft() {
        let model = EnhancedLyricsSettingsModel()
        model.draftKey = "sl_sk_" + String(repeating: "a", count: 30)
        model.cancelEditing()
        XCTAssertEqual(model.draftKey, "")
        XCTAssertFalse(model.hasSavedKey)
    }
}
