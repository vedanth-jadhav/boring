import XCTest
@testable import boringNotch

final class LyricsTimingTests: XCTestCase {
    func testPunjabiAndMixedEnglish() {
        XCTAssertEqual(LyricsRomanizer.romanize("ਪੱਗ ਪੰਜਾਬੀ ਦਿਲ ਤੇਰਾ ਪਿਆਰ ਨਹੀਂ tonight"), "pagg punjabi dil tera pyaar nahi tonight")
        XCTAssertEqual(LyricsRomanizer.romanize("ਸੁਪਨਾ ਸੋਹਣਾ"), "supna sohna")
        XCTAssertEqual(LyricsRomanizer.romanize("ਰੱਤਾ"), "rattaa")
    }

    func testHindiAndUrduKeepPunctuation() {
        XCTAssertEqual(LyricsRomanizer.romanize("तेरा मेरा प्यार दिल नहीं है!"), "tera mera pyaar dil nahi hai!")
        XCTAssertEqual(LyricsRomanizer.romanize("تم میرا دل ہے نہیں پیار عشق"), "tum mera dil hai nahi pyaar ishq")
        XCTAssertEqual(LyricsRomanizer.romanize("مینوں تینوں نال پیار"), "mainu tainu naal pyaar")
        XCTAssertEqual(LyricsRomanizer.romanize("Stay with me, tonight!"), "Stay with me, tonight!")
        XCTAssertEqual(LyricsRomanizer.romanize("گھر"), "ghar")
    }

    func testFractionalRepeatedAndEmptyLRCStamps() {
        let lines = LyricLine.parseLRC("[00:01.5][00:03.050]Hello\n[00:05.005]\n[ar:Artist]")
        XCTAssertEqual(lines.map(\.start), [1.5, 3.05, 5.005])
        XCTAssertEqual(lines.map(\.text), ["Hello", "Hello", ""])
    }

    func testEnhancedLRCAndRepeatedWordTimings() {
        let lines = LyricLine.parseLRC("[00:10][00:20]<00:10.1>Hello <00:10.6>world<00:11.2>")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[0].words.map(\.start), [10.1, 10.6])
        XCTAssertEqual(lines[0].words.map(\.end), [10.6, 11.2])
        XCTAssertEqual(lines[1].words.map(\.start), [20.1, 20.6])
    }

    func testEnhancedLRCWithoutTerminalStampKeepsLastWord() {
        let line = LyricLine.parseLRC("[00:10]<00:10>Hello <00:11>world")[0]
        XCTAssertEqual(line.text, "Hello world")
        XCTAssertTrue(line.words.isEmpty)
        XCTAssertEqual(line.resolvedWords(until: 12).map(\.text), ["Hello", "world"])
    }

    func testExactWordsKeepInstrumentalGaps() {
        let words = [LyricLine.Word(text: "one", start: 10, end: 10.5),
                     LyricLine.Word(text: "two", start: 11, end: 11.5)]
        let line = LyricLine(start: 10, end: 12, text: "one two", words: words)
        XCTAssertEqual(line.resolvedWords(until: 15), words)
        XCTAssertNil(words.lastIndex { 10.8 >= $0.start && 10.8 < $0.end })
        XCTAssertEqual(words.lastIndex { 11.1 >= $0.start && 11.1 < $0.end }, 1)
    }

    func testLineOnlyTimingUsesWholeWindowAndUnicodeTokens() {
        let line = LyricLine(start: 5, end: nil, text: "ਤੇਰਾ  ਮੇਰਾ\nਪਿਆਰ")
        let words = line.resolvedWords(until: 8)
        XCTAssertEqual(words.map(\.text), ["ਤੇਰਾ", "ਮੇਰਾ", "ਪਿਆਰ"])
        XCTAssertEqual(words.first?.start, 5)
        XCTAssertEqual(words.last!.end, 8, accuracy: 0.000001)
        XCTAssertEqual(words[0].end, words[1].start)
        XCTAssertTrue(LyricLine(start: 0, end: nil, text: "").resolvedWords(until: 1).isEmpty)
    }

    func testBroaderScriptsAndAccentedLatinStayReadable() {
        XCTAssertEqual(LyricsRomanizer.romanize("தமிழ் / తెలుగు / ગુજરાતી / বাংলা"), "tamiḻ / telugu / gujarātī / bānlā")
        XCTAssertEqual(LyricsRomanizer.romanize("안녕 (Привет)"), "annyeong (Privet)")
        XCTAssertEqual(LyricsRomanizer.romanize("こんにちは"), "kon'nichiha")
        let latin = "Beyoncé — déjà vu, cafe\u{301} ❤️ १२३"
        XCTAssertEqual(LyricsRomanizer.romanize(latin), latin)
    }

    func testEquivalentUnicodeFormsAndJoinersDoNotChangeSpelling() {
        XCTAssertEqual(LyricsRomanizer.romanize("क़ ख़ ਖ਼"), "q kh kh")
        XCTAssertEqual(LyricsRomanizer.romanize("क़ ख़ ਖ਼"), "q kh kh")
        XCTAssertEqual(LyricsRomanizer.romanize("प्या\u{200D}र"), "pyaar")
        XCTAssertEqual(LyricsRomanizer.romanize("گھر تمہارا خواب"), "ghar tumhaara khwaab")
    }

    func testIraadayVowelsAndOptionalUrduMarksAreReadable() {
        XCTAssertEqual(LyricsRomanizer.romanize("کیسا سماں ہے، ہم تم یہاں ہیں"), "kaisa samaa hai, hum tum yahaan hain")
        XCTAssertEqual(LyricsRomanizer.romanize("میرے اِرادے"), "mere iraaday")
        XCTAssertEqual(LyricsRomanizer.romanize("میرے ارادے"), "mere iraaday")
        XCTAssertEqual(LyricsRomanizer.romanize("زندگي ہے؟"), "zindagi hai?")
        XCTAssertEqual(LyricsRomanizer.romanize("कैसा समां है हम तुम यहाँ हैं"), "kaisa samaan hai hum tum yahaan hain")
    }

    func testAttestedSpellingsRecoverMissingVowelsAndMedialSchwa() {
        XCTAssertEqual(LyricsRomanizer.romanize("جذبات ظاہر حوالے بہانے"), "jazbaat zaahir hawaale bahaane")
        XCTAssertEqual(LyricsRomanizer.romanize("जीवन अपनी रास्ता धड़कन लम्हे"), "jeevan apni rasta dhadkan lamhe")
    }

    func testBundledLexiconsHaveCompleteIndexesAndUnknownWordsFallBack() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["BORING_ROMANIZATION_RESOURCES"].map {
            URL(fileURLWithPath: $0)
        } ?? Bundle.main.resourceURL?.appendingPathComponent("Romanization"))
        for (language, expected) in [("hi", 30000), ("pa", 30000), ("ur", 28100)] {
            let table = try XCTUnwrap(RomanizationLexicon(url: directory.appendingPathComponent(language + ".lexicon")))
            XCTAssertEqual(table.count, expected)
            XCTAssertNil(table.romanization(for: "not a source word"))
            XCTAssertNil(table.romanization(for: ""))
        }
        XCTAssertNil(RomanizationLexicon(url: directory.appendingPathComponent("missing.lexicon")))
    }
}
