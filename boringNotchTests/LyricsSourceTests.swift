import XCTest
import Foundation
@testable import boringNotch

private final class LyricLookupProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var body = Data()
    private static var requests: [URL] = []
    static func configure(_ rows: [[String: Any]]) throws {
        lock.lock(); defer { lock.unlock() }
        body = try JSONSerialization.data(withJSONObject: rows)
        requests = []
    }
    static var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request.url!)
        let data = Self.body
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class LyricsSourceTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricLookupProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testVideoMetadataAndTopicChannelsResolveWithoutChangingVersionNames() {
        let video = LyricTrackQuery(title: "Fixture Artist - Song (Official Video) [4K]", artist: "Record Label",
                                   bundleIdentifier: "com.brave.Browser")
        XCTAssertEqual(video.title, "Song")
        XCTAssertEqual(video.artist, "Fixture Artist")
        XCTAssertEqual(LyricTrackQuery(title: "Song", artist: "Fixture Artist - Topic").artist, "Fixture Artist")
        XCTAssertEqual(LyricTrackQuery(title: "Song", artist: "Fixture ArtistVEVO").artist, "Fixture Artist")
        let live = LyricTrackQuery(title: "Song - Live", artist: "Fixture Artist", bundleIdentifier: "com.google.Chrome")
        XCTAssertEqual(live.title, "Song - Live")
        XCTAssertEqual(live.artist, "Fixture Artist")
        XCTAssertEqual(LyricTrackQuery(title: "Song (Acoustic Remix)", artist: "Artist").title, "Song (Acoustic Remix)")
    }

    func testLookupQueryEncodesAmpersandsPlusAndUnicodeAsValues() {
        let query = LyricTrackQuery(title: "Love + Hate & Échos?", artist: "Earth, Wind & Fire")
        let url = query.searchURL(includeArtist: true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].value, query.title)
        XCTAssertEqual(items[1].value, query.artist)
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        XCTAssertTrue(url.absoluteString.contains("%26"))
    }

    func testMatchingRejectsWrongSongsCoversVersionsAndAmbiguousTitles() {
        let query = LyricTrackQuery(title: "Song", artist: "Artist", duration: 200)
        func result(_ title: String, _ artist: String, _ duration: Double) -> [String: Any] {
            ["trackName": title, "artistName": artist, "duration": duration, "plainLyrics": "Words"]
        }
        XCTAssertNil(query.bestMatch(in: [result("Other Song", "Artist", 200)]))
        XCTAssertNil(query.bestMatch(in: [result("Song", "Cover Artist", 200)]))
        XCTAssertNil(query.bestMatch(in: [result("Song - Live", "Artist", 200)]))
        XCTAssertNil(query.bestMatch(in: [result("Song", "Artist", 245)]))
        XCTAssertNil(LyricTrackQuery(title: "Song", artist: "").bestMatch(in: [
            result("Song", "One", 200), result("Song", "Two", 200)
        ]))
        var timed = result("Song", "Artist", 201)
        timed["syncedLyrics"] = "[00:01.00]Words"
        let selected = query.bestMatch(in: [result("Song", "Artist", 200), timed])
        XCTAssertEqual(selected?["syncedLyrics"] as? String, "[00:01.00]Words")
    }

    func testSpotifyBrowsersYouTubeMusicAndOtherPlayersRetainLineTimingWithoutGuessingWords() async throws {
        for source in ["com.spotify.client", "com.brave.Browser", "com.google.Chrome", "com.apple.Safari",
                       "org.mozilla.firefox", "com.microsoft.edgemac", "com.github.th-ch.youtube-music", "org.videolan.vlc"] {
            let title = "Source fixture \(UUID())"
            try LyricLookupProtocol.configure([["trackName": title, "artistName": "Fixture Artist", "duration": 200,
                "plainLyrics": "One two\nNext line", "syncedLyrics": "[00:01.00]One two\n[00:03.00]Next line"]])
            let service = LyricsService(webSession: session())
            let browser = !["com.spotify.client", "com.github.th-ch.youtube-music", "org.videolan.vlc"].contains(source)
            await service.fetchLyrics(bundleIdentifier: source,
                title: browser ? "Fixture Artist - \(title) (Official Video)" : title,
                artist: browser ? "Record Label" : "Fixture Artist - Topic", duration: 200, useEnhancedLyrics: false)
            XCTAssertEqual(service.timedLyrics.count, 2, source)
            let row = try XCTUnwrap(service.displayedRow(at: 1.5)?.row)
            XCTAssertFalse(row.highlightsWords, source)
            XCTAssertFalse(row.shouldAnimate(at: 1.5, rate: 1, playing: true, reduceMotion: false), source)
            XCTAssertFalse(row.shouldAnimate(at: 1.5, rate: 1, playing: false, reduceMotion: false), source)
            XCTAssertEqual(LyricLookupProtocol.requestedURLs.count, 1)
            service.clearLyrics()
        }
    }

    func testCachedPlainLyricsUpgradeToTimedLyricsAndSurviveAnEmptyResponse() async throws {
        let title = "Upgrade fixture \(UUID())"
        let service = LyricsService(webSession: session())
        service.setProviderLyrics([], plainLyrics: "Readable plain lyrics", title: title, artist: "Artist")
        try LyricLookupProtocol.configure([])
        await service.fetchLyrics(bundleIdentifier: "com.spotify.client", title: title, artist: "Artist", useEnhancedLyrics: false)
        XCTAssertEqual(service.currentLyrics, "Readable plain lyrics")
        try LyricLookupProtocol.configure([["trackName": title, "artistName": "Artist", "duration": 200,
            "syncedLyrics": "[00:01.00]One two\n[00:03.00]Next line"]])
        await service.fetchLyrics(bundleIdentifier: "com.spotify.client", title: title, artist: "Artist", duration: 200, useEnhancedLyrics: false)
        XCTAssertEqual(service.timedLyrics.count, 2)
        XCTAssertEqual(service.currentLyrics, "One two\nNext line")
        service.setProviderLyrics([], plainLyrics: "Late plain response", title: title, artist: "Artist")
        XCTAssertEqual(service.timedLyrics.count, 2)
        service.clearLyrics()
    }
}
