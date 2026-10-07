import CryptoKit
import Foundation

/// Runs metadata matching and lyric parsing away from the display clock.
actor SpicyLyricsClient {
    static let shared = SpicyLyricsClient()

    private struct CachedLyrics: Codable {
        let savedAt: Date
        let payload: SpicyLyricsPayload
    }
    private struct AlbumTracks: Codable {
        struct Track: Codable {
            let id: String
            let title: String
            let artist: String
            let duration: Double
        }
        let savedAt: Date
        let tracks: [Track]
    }
    private enum FetchError: Error { case unavailable }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpAdditionalHeaders = ["User-Agent": "BoringNotchOctave/2.8.1 (personal lyric display)"]
        return URLSession(configuration: configuration)
    }()
    private let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("local.vedanth.boringnotch.octave/SpicyLyrics", isDirectory: true)
    private var key: String?
    private var credentialLoaded = false
    private var failedUntil: [String: Date] = [:]
    private var serverRetry: [String: Date] = [:]
    private var nextMetadataRequest = Date.distantPast

    init(credential: String? = nil) { key = credential; credentialLoaded = credential != nil }

    enum KeyValidation: Equatable {
        case valid, invalid, restricted, rateLimited, unavailable
    }

    func validateCredential(_ credential: String) async -> KeyValidation {
        guard SpicyLyricsCredential.accepts(credential) else { return .invalid }
        var request = URLRequest(url: URL(string: "https://api.spicylyrics.org/v1/lyrics/1QV6tiMFM6fSOKOGLMHYYg")!)
        request.setValue("Bearer \(credential.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, let http = response as? HTTPURLResponse else { return .unavailable }
            switch http.statusCode {
            case 200: return SpicyLyricsPayload.parse(data) != nil ? .valid : .unavailable
            case 401: return .invalid
            case 403: return .restricted
            case 429: return .rateLimited
            default: return .unavailable
            }
        } catch { return .unavailable }
    }

    func reloadCredential() {
        key = nil
        credentialLoaded = false
        failedUntil.removeAll(keepingCapacity: true)
        serverRetry.removeAll(keepingCapacity: true)
    }

    func fetch(title: String, artist: String, album: String, duration: Double) async -> SpicyLyricsPayload? {
        let duration = duration.isFinite && duration > 0 ? min(duration, 86400) : 0
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        if !credentialLoaded {
            key = SpicyLyricsCredential.load()
            credentialLoaded = true
        }
        guard let key else { return nil }
        let identity = [normalized(title), normalized(artist), normalized(album), String(Int(duration.rounded()))].joined(separator: "|")
        let cacheURL = cacheDirectory.appendingPathComponent("lyrics-\(digest(identity)).json")
        if let cached: CachedLyrics = read(cacheURL),
           Date().timeIntervalSince(cached.savedAt) < (cached.payload.precision == 2 ? 30 : 1) * 86400 {
            return cached.payload
        }
        guard !Task.isCancelled, failedUntil[identity, default: .distantPast] <= Date() else { return nil }
        do {
            guard let id = try await resolveTrack(title: title, artist: artist, album: album, duration: duration) else {
                rememberFailure(identity, seconds: 3600)
                return nil
            }
            try Task.checkCancellation()
            let url = URL(string: "https://api.spicylyrics.org/v1/lyrics/\(id)")!
            let data = try await request(url, authorization: key)
            guard let payload = SpicyLyricsPayload.parse(data) else {
                rememberFailure(identity, seconds: 3600)
                return nil
            }
            try Task.checkCancellation()
            write(CachedLyrics(savedAt: Date(), payload: payload), to: cacheURL)
            NSLog("Spicy Lyrics imported: %d rows, precision %d", payload.lines.count, payload.precision)
            return payload
        } catch {
            if !Task.isCancelled { rememberFailure(identity, seconds: 120) }
            return nil
        }
    }

    private func resolveTrack(title: String, artist: String, album: String, duration: Double) async throws -> String? {
        let albumURL = cacheDirectory.appendingPathComponent("album-\(digest(normalized(artist) + "|" + normalized(album))).json")
        if !album.isEmpty, let cached: AlbumTracks = read(albumURL),
           Date().timeIntervalSince(cached.savedAt) < 30 * 86400,
           let id = matchingTrack(cached.tracks, title: title, artist: artist, duration: duration) { return id }

        // MusicBrainz links releases to Spotify albums. Spotify's public embed
        // carries track IDs and durations, without an additional API credential.
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let query = "recording:\(quoted(title)) AND artist:\(quoted(artist))"
        let searchURL = makeURL("https://musicbrainz.org/ws/2/recording/", ["query": query, "fmt": "json", "limit": "5"])
        let search = try await json(searchURL)
        let recordings = (search["recordings"] as? [[String: Any]] ?? []).filter { recording in
            guard normalized(recording["title"] as? String ?? "") == normalized(title),
                  (recording["score"] as? Int ?? 0) >= 95 else { return false }
            let credits = (recording["artist-credit"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            guard credits.contains(where: { artistMatches($0, artist) }) else { return false }
            let length = (recording["length"] as? Double ?? 0) / 1000
            return duration <= 0 || length <= 0 || abs(length - duration) <= 4
        }
        var releases = recordings.flatMap { $0["releases"] as? [[String: Any]] ?? [] }
        releases.sort { normalized($0["title"] as? String ?? "") == normalized(album)
            && normalized($1["title"] as? String ?? "") != normalized(album) }
        var seen = Set<String>()
        for release in releases.filter({ seen.insert($0["id"] as? String ?? "").inserted }).prefix(3) {
            try Task.checkCancellation()
            guard let releaseID = release["id"] as? String,
                  UUID(uuidString: releaseID) != nil else { continue }
            let details = try await json(makeURL("https://musicbrainz.org/ws/2/release/\(releaseID)", ["inc": "url-rels", "fmt": "json"]))
            let relations = details["relations"] as? [[String: Any]] ?? []
            let urls = relations.compactMap { ($0["url"] as? [String: Any])?["resource"] as? String }
            for resource in urls {
                guard let spotifyURL = URL(string: resource), spotifyURL.host == "open.spotify.com",
                      spotifyURL.pathComponents.count == 3, spotifyURL.pathComponents[1] == "album",
                      validSpotifyID(spotifyURL.lastPathComponent) else { continue }
                let data = try await request(URL(string: "https://open.spotify.com/embed/album/\(spotifyURL.lastPathComponent)")!)
                guard let entity = embedEntity(data), let rows = entity["trackList"] as? [[String: Any]] else { continue }
                let tracks = rows.compactMap { row -> AlbumTracks.Track? in
                    guard let uri = row["uri"] as? String, uri.hasPrefix("spotify:track:"),
                          let id = uri.split(separator: ":").last.map(String.init), validSpotifyID(id),
                          let title = row["title"] as? String, let artist = row["subtitle"] as? String else { return nil }
                    return .init(id: id, title: title, artist: artist, duration: (row["duration"] as? Double ?? 0) / 1000)
                }
                if let id = matchingTrack(tracks, title: title, artist: artist, duration: duration) {
                    if !album.isEmpty { write(AlbumTracks(savedAt: Date(), tracks: tracks), to: albumURL) }
                    return id
                }
            }
        }
        return nil
    }

    private func matchingTrack(_ tracks: [AlbumTracks.Track], title: String, artist: String, duration: Double) -> String? {
        tracks.filter {
            normalized($0.title) == normalized(title) && artistMatches($0.artist, artist)
                && (duration <= 0 || ($0.duration > 0 && abs($0.duration - duration) <= 4))
        }.min { abs($0.duration - duration) < abs($1.duration - duration) }?.id
    }

    private func artistMatches(_ candidate: String, _ artist: String) -> Bool {
        let lhs = normalized(candidate), rhs = normalized(artist)
        return !rhs.isEmpty && (lhs == rhs || rhs.count >= 3 && lhs.contains(rhs))
    }

    private func embedEntity(_ data: Data) -> [String: Any]? {
        guard let html = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: #"<script\b[^>]*\bid="__NEXT_DATA__"[^>]*>(.*?)</script>"#,
                                                       options: .dotMatchesLineSeparators),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let jsonData = String(html[range]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let props = root["props"] as? [String: Any], let page = props["pageProps"] as? [String: Any],
              let state = page["state"] as? [String: Any], let stateData = state["data"] as? [String: Any] else { return nil }
        return stateData["entity"] as? [String: Any]
    }

    private func json(_ url: URL) async throws -> [String: Any] {
        let data = try await request(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.unavailable }
        return object
    }

    private func request(_ url: URL, authorization: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        let host = url.host ?? ""
        guard serverRetry[host, default: .distantPast] <= Date() else { throw FetchError.unavailable }
        if host == "musicbrainz.org" {
            let slot = max(Date(), nextMetadataRequest)
            nextMetadataRequest = slot.addingTimeInterval(1.1)
            let delay = slot.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        var request = URLRequest(url: url)
        if let authorization {
            guard host == "api.spicylyrics.org", url.scheme == "https" else { throw FetchError.unavailable }
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw FetchError.unavailable }
        guard http.statusCode == 200, data.count <= 4_000_000 else {
            if http.statusCode == 429 || http.statusCode == 401 || http.statusCode == 403 || http.statusCode >= 500 {
                let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 120
                serverRetry[host] = Date().addingTimeInterval(max(30, min(3600, retry)))
            }
            NSLog("Lyric provider request unavailable (%@, HTTP %d)", host, http.statusCode)
            throw FetchError.unavailable
        }
        return data
    }

    private func makeURL(_ base: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
    private func validSpotifyID(_ id: String) -> Bool {
        id.count == 22 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func rememberFailure(_ identity: String, seconds: Double) {
        if failedUntil.count >= 128 { failedUntil = failedUntil.filter { $0.value > Date() } }
        if failedUntil.count >= 128 { failedUntil.removeAll(keepingCapacity: true) }
        failedUntil[identity] = Date().addingTimeInterval(seconds)
    }
    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url), data.count <= 4_000_000 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        // Bound persistent storage; this runs only after a successful import.
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 256 {
            let sorted = files.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for file in sorted.prefix(files.count - 256) { try? FileManager.default.removeItem(at: file) }
        }
    }
}
