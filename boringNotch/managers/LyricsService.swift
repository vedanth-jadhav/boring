//
//  LyricsService.swift
//  boringNotch
//
//  Extracted from MusicManager for better separation of concerns.
//

import AppKit
import Combine
import Defaults
import Foundation

/// Service responsible for fetching and parsing lyrics for the currently playing track.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published private(set) var timedLyrics: [LyricLine] = [] {
        didSet { timeline = LyricTimeline(lines: timedLyrics); cachedFrame = nil }
    }
    @Published private(set) var attribution: LyricAttribution?
    private var timeline = LyricTimeline(lines: [])
    private var cachedFrame: (bucket: Int, duration: Double, frame: LyricVocalFrame)?

    // Cache to avoid redundant fetches; NSCache evicts under memory pressure
    // instead of growing for the whole session.
    private final class LyricsEntry {
        let plain: String
        let synced: [(time: Double, text: String)]
        let timed: [LyricLine]
        let attribution: LyricAttribution?
        var precision: Int { timed.contains { !$0.words.isEmpty } ? 2 : (timed.isEmpty ? 0 : 1) }
        init(plain: String, synced: [(time: Double, text: String)], timed: [LyricLine]? = nil,
             attribution: LyricAttribution? = nil) {
            self.plain = plain
            self.synced = synced
            self.timed = timed ?? synced.map { LyricLine(start: $0.time, end: nil, text: $0.text) }
            self.attribution = attribution
        }
    }
    private let lyricsCache = NSCache<NSString, LyricsEntry>()
    private let enhancedCache = NSCache<NSString, LyricsEntry>()
    private var currentFetchTask: Task<Void, Never>?
    private var spicyFetchTask: Task<Void, Never>?
    private var activeCacheKey: String?
    private var activeUseEnhanced = false
    private struct FetchContext {
        let bundleIdentifier: String?
        let title: String
        let artist: String
        let preferProvider: Bool
        let album: String
        let duration: Double
    }
    private var fetchContext: FetchContext?
    private var configurationTask: Task<Void, Never>?
    private var preferenceSubscription: AnyCancellable?

    private init() {
        lyricsCache.countLimit = 80
        enhancedCache.countLimit = 80
        // An existing personal key represents the earlier explicit opt-in.
        // Fresh installations use the public project's disabled default.
        if UserDefaults.standard.object(forKey: "enableEnhancedLyrics") == nil, SpicyLyricsCredential.load() != nil {
            Defaults[.enableEnhancedLyrics] = true
        }
        preferenceSubscription = Defaults.publisher(.enableEnhancedLyrics, options: []).sink { [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        }
    }

    // MARK: - Public API

    /// Fetches lyrics for the given track, preferring native Apple Music lyrics when available.
    func fetchLyrics(bundleIdentifier: String?, title: String, artist: String,
                     preferProvider: Bool = false, album: String = "", duration: Double = 0,
                     useEnhancedLyrics: Bool? = nil) async {
        // Cancel any pending fetch
        currentFetchTask?.cancel()
        spicyFetchTask?.cancel()

        guard !title.isEmpty else {
            clearLyrics()
            return
        }

        // Check cache first
        let cacheKey = cacheKey(title: title, artist: artist)
        activeCacheKey = cacheKey
        activeUseEnhanced = useEnhancedLyrics ?? Defaults[.enableEnhancedLyrics]
        fetchContext = FetchContext(bundleIdentifier: bundleIdentifier, title: title, artist: artist,
                                    preferProvider: preferProvider, album: album, duration: duration)
        // A provider's quick line response must not cancel the richer import.
        // Lyrics from Spicy replace both text and timestamps as one payload.
        if activeUseEnhanced {
          spicyFetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let payload = await SpicyLyricsClient.shared.fetch(title: title, artist: artist, album: album, duration: duration)
            guard !Task.isCancelled, self.activeUseEnhanced, self.activeCacheKey == cacheKey, let payload else { return }
            self.setProviderLyrics(payload.lines, plainLyrics: payload.plain, title: title, artist: artist,
                                   attribution: payload.attribution)
          }
        }
        if let cached = preferredEntry(for: cacheKey) {
            apply(cached)
            return
        }

        isFetchingLyrics = true
        currentLyrics = ""
        syncedLyrics = []
        timedLyrics = []
        attribution = nil

        let task = Task { [weak self] in
            guard let self = self else { return }

            // Octave's page asks its own lyrics endpoint once per track. Give
            // that response first choice; a single timeout keeps the existing
            // web source available if the page has no lyrics or disconnects.
            if preferProvider {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled, self.activeCacheKey == cacheKey,
                      self.lyricsCache.object(forKey: cacheKey as NSString) == nil else { return }
            }

            // Try Apple Music first if applicable
            if let bundleIdentifier = bundleIdentifier, bundleIdentifier.contains(MediaAppBundleID.appleMusic) {
                if let lyrics = await self.fetchAppleMusicLyrics() {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.currentLyrics = lyrics
                        self.syncedLyrics = []
                        self.timedLyrics = []
                        self.isFetchingLyrics = false
                        self.lyricsCache.setObject(LyricsEntry(plain: lyrics, synced: []), forKey: cacheKey as NSString)
                    }
                    return
                }
            }

            // Fallback to web
            guard !Task.isCancelled else { return }
            let webResult = await self.fetchLyricsFromWeb(title: title, artist: artist)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.activeCacheKey == cacheKey else { return }
                self.currentLyrics = webResult.plain
                self.syncedLyrics = webResult.synced
                self.timedLyrics = webResult.timed
                self.isFetchingLyrics = false
                if !webResult.plain.isEmpty {
                    self.lyricsCache.setObject(LyricsEntry(plain: webResult.plain, synced: webResult.synced, timed: webResult.timed), forKey: cacheKey as NSString)
                }
            }
        }

        currentFetchTask = task
        await task.value
    }

    /// Clears all lyrics data.
    func clearLyrics() {
        configurationTask?.cancel()
        configurationTask = nil
        fetchContext = nil
        currentFetchTask?.cancel()
        currentFetchTask = nil
        spicyFetchTask?.cancel()
        spicyFetchTask = nil
        activeCacheKey = nil
        activeUseEnhanced = false
        currentLyrics = ""
        syncedLyrics = []
        timedLyrics = []
        attribution = nil
        isFetchingLyrics = false
    }

    /// Toggle/key changes refresh the current song, without waiting for a skip.
    func configurationChanged() {
        configurationTask?.cancel()
        currentFetchTask?.cancel()
        spicyFetchTask?.cancel()
        activeUseEnhanced = Defaults[.enableEnhancedLyrics]
        guard let context = fetchContext else { return }
        if let key = activeCacheKey, let cached = preferredEntry(for: key) { apply(cached) }
        configurationTask = Task { [weak self] in
            await SpicyLyricsClient.shared.reloadCredential()
            guard !Task.isCancelled, let self,
                  self.activeCacheKey == self.cacheKey(title: context.title, artist: context.artist) else { return }
            await self.fetchLyrics(bundleIdentifier: context.bundleIdentifier, title: context.title, artist: context.artist,
                                  preferProvider: context.preferProvider, album: context.album, duration: context.duration)
        }
    }

    private func preferredEntry(for key: String) -> LyricsEntry? {
        let regular = lyricsCache.object(forKey: key as NSString)
        guard activeUseEnhanced, let enhanced = enhancedCache.object(forKey: key as NSString) else { return regular }
        return enhanced.precision >= (regular?.precision ?? -1) ? enhanced : regular
    }

    private func apply(_ entry: LyricsEntry) {
        if currentLyrics != entry.plain { currentLyrics = entry.plain }
        syncedLyrics = entry.synced
        if timedLyrics != entry.timed { timedLyrics = entry.timed }
        if attribution != entry.attribution { attribution = entry.attribution }
        isFetchingLyrics = false
    }

    /// Retain Octave's absolute word timestamps, including instrumental gaps.
    func setProviderLyrics(_ lines: [LyricLine], plainLyrics: String = "", title: String, artist: String,
                           attribution sourceAttribution: LyricAttribution? = nil) {
        let key = cacheKey(title: title, artist: artist)
        let sorted = lines.filter { $0.start.isFinite && $0.start >= 0 }.map { line in
            let words = line.words.filter {
                $0.start.isFinite && $0.end.isFinite && $0.start >= line.start && $0.end > $0.start
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.map {
                LyricLine.Word(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start, end: $0.end, isBackground: $0.isBackground)
            }
            return LyricLine(start: line.start, end: line.end.flatMap { $0.isFinite && $0 > line.start ? $0 : nil },
                             text: line.text, words: words.count == line.words.count ? words : [], isBackground: line.isBackground)
        }.sorted { $0.start < $1.start }
        let plain = sourceAttribution != nil || sorted.isEmpty ? plainLyrics : sorted.map(\.text).joined(separator: "\n")
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let synced = sorted.map { (time: $0.start, text: $0.text) }
        let entry = LyricsEntry(plain: plain, synced: synced, timed: sorted, attribution: sourceAttribution)
        let cache = sourceAttribution == nil ? lyricsCache : enhancedCache
        if let cached = cache.object(forKey: key as NSString), cached.precision > entry.precision { return }
        cache.setObject(entry, forKey: key as NSString)
        guard activeCacheKey == key, let selected = preferredEntry(for: key) else { return }
        currentFetchTask?.cancel()
        currentFetchTask = nil
        apply(selected)
    }

    /// Return every concurrent vocal, preserving simultaneous line timestamps.
    func activeLines(at elapsed: Double, duration: Double) -> [LyricTimeline.Entry] {
        timeline.active(at: elapsed, duration: duration)
    }

    func displayedLines(at elapsed: Double, duration: Double) -> [LyricTimeline.Entry] {
        timeline.displayed(at: elapsed, duration: duration)
    }

    func displayedRow(at elapsed: Double) -> LyricVocalFrame.Row? {
        timeline.displayedPrimary(at: elapsed)?.vocalRows.primary
    }

    func vocalFrame(at elapsed: Double, duration: Double) -> LyricVocalFrame {
        guard elapsed.isFinite, elapsed >= 0 else { return LyricVocalFrame(entries: [], elapsed: 0) }
        // Crossing the track's end also changes active secondary lanes.
        let bucket = elapsed >= duration ? -1 : timeline.displayBucket(at: elapsed)
        if let cachedFrame, cachedFrame.bucket == bucket, cachedFrame.duration == duration {
            return cachedFrame.frame
        }
        let frame = LyricVocalFrame(entries: timeline.displayed(at: elapsed, duration: duration), elapsed: elapsed)
        cachedFrame = (bucket, duration, frame)
        return frame
    }

    var hasWordTimings: Bool { timeline.hasWordTimings }

    /// The shared row clock paints words. The song-level view only needs row
    /// and silence boundaries, unless Reduce Motion disables that local clock.
    func displayDates(anchorPosition: Double, anchorDate: Date, rate: Double, playing: Bool,
                      wordBoundaries: Bool = true, singleRow: Bool = false) -> [Date] {
        guard playing, rate > 0 else { return [.now] }
        let now = Date()
        let boundaries = singleRow
            ? (wordBoundaries ? timeline.singleRowWordBoundaries : timeline.singleRowBoundaries)
            : (wordBoundaries ? timeline.displayBoundaries : timeline.rowDisplayBoundaries)
        return [now] + boundaries.map {
            // Date/Double conversion can round just before the source stamp.
            // One microsecond prevents evaluating the previous word at an end.
            anchorDate.addingTimeInterval(($0 - anchorPosition) / rate + 0.000001)
        }.filter { $0 > now }
    }

    /// Constant within a track so controls don't jump during backing vocals.
    var hasConcurrentVocals: Bool { timeline.hasConcurrentVocals }

    func timedLine(at elapsed: Double) -> (line: LyricLine, nextStart: Double?)? {
        guard let context = activeLines(at: elapsed, duration: .greatestFiniteMagnitude).first else { return nil }
        return (context.line, context.nextStart)
    }

    /// Returns the lyric line at the given elapsed time for synced lyrics.
    func lyricLine(at elapsed: Double) -> String {
        lyricLineContext(at: elapsed).text
    }

    /// Returns the active synced lyric line and its timing window.
    func lyricLineContext(at elapsed: Double) -> (text: String, startTime: Double, endTime: Double?) {
        guard !syncedLyrics.isEmpty else { return (currentLyrics, 0, nil) }
        guard let context = timedLine(at: elapsed) else { return ("", 0, nil) }
        return (context.line.text, context.line.start, context.line.end ?? context.nextStart)
    }

    // MARK: - Private Methods

    private func cacheKey(title: String, artist: String) -> String {
        "\(normalizedQuery(title))|\(normalizedQuery(artist))"
    }

    private func fetchAppleMusicLyrics() async -> String? {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
        guard !runningApps.isEmpty else { return nil }

        let script = """
        tell application "Music"
            if it is running then
                if player state is playing or player state is paused then
                    try
                        set l to lyrics of current track
                        if l is missing value then
                            return ""
                        else
                            return l
                        end if
                    on error
                        return ""
                    end try
                else
                    return ""
                end if
            else
                return ""
            end if
        end tell
        """

        do {
            if let result = try await AppleScriptHelper.execute(script),
               let lyricsString = result.stringValue,
               !lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return lyricsString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // Fall through to return nil
        }
        return nil
    }

    private func fetchLyricsFromWeb(title: String, artist: String) async -> (plain: String, synced: [(time: Double, text: String)], timed: [LyricLine]) {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)

        guard let encodedTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ("", [], [])
        }

        // Try with artist first, then without if no results
        let searchStrategies: [String] = {
            var strategies: [String] = []

            // Strategy 1: Search with artist (if provided)
            if !cleanArtist.isEmpty,
               let encodedArtist = cleanArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                strategies.append("https://lrclib.net/api/search?track_name=\(encodedTitle)&artist_name=\(encodedArtist)")
            }

            // Strategy 2: Search with title only (always include as fallback)
            strategies.append("https://lrclib.net/api/search?track_name=\(encodedTitle)")

            return strategies
        }()

        for urlString in searchStrategies {
            guard let url = URL(string: urlString) else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continue
                }

                if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = findBestMatch(in: jsonArray, title: cleanTitle, artist: cleanArtist) {
                    let plain = (first["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let synced = (first["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if !plain.isEmpty || !synced.isEmpty {
                        let resolvedPlain = plain.isEmpty ? synced : plain
                        let timed = LyricLine.parseLRC(synced)
                        let parsedSynced = timed.map { (time: $0.start, text: $0.text) }
                        return (resolvedPlain, parsedSynced, timed)
                    }
                }
            } catch {
                continue
            }
        }

        return ("", [], [])
    }

    /// Find the best matching result from the search results based on title similarity
    private func findBestMatch(in results: [[String: Any]], title: String, artist: String) -> [String: Any]? {
        guard !results.isEmpty else { return nil }

        // If only one result, use it
        if results.count == 1 { return results.first }

        let normalizedTitle = title.lowercased()
        let normalizedArtist = artist.lowercased()

        // Score each result and pick the best
        var bestResult: [String: Any]?
        var bestScore = 0

        for result in results {
            var score = 0

            // Check title match
            if let resultTitle = result["trackName"] as? String {
                if resultTitle.lowercased() == normalizedTitle {
                    score += 10
                } else if resultTitle.lowercased().contains(normalizedTitle) || normalizedTitle.contains(resultTitle.lowercased()) {
                    score += 5
                }
            }

            // Check artist match (bonus if provided and matches)
            if !normalizedArtist.isEmpty, let resultArtist = result["artistName"] as? String {
                if resultArtist.lowercased() == normalizedArtist {
                    score += 8
                } else if resultArtist.lowercased().contains(normalizedArtist) || normalizedArtist.contains(resultArtist.lowercased()) {
                    score += 4
                }
            }

            // Prefer results with lyrics
            if let plain = result["plainLyrics"] as? String, !plain.isEmpty {
                score += 2
            }
            if let synced = result["syncedLyrics"] as? String, !synced.isEmpty {
                score += 3
            }

            if score > bestScore {
                bestScore = score
                bestResult = result
            }
        }

        return bestResult ?? results.first
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
