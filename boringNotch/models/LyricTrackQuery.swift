import Foundation

/// Normalize lookup metadata, leaving the player's displayed title untouched.
struct LyricTrackQuery {
    let title: String
    let artist: String
    let album: String
    let duration: Double

    init(title: String, artist: String, album: String = "", duration: Double = 0, bundleIdentifier: String? = nil) {
        let original = Self.trim(title)
        var title = original
        var artist = Self.trim(artist)
            .replacingOccurrences(of: #"(?i)\s*-\s*Topic$|VEVO$"#, with: "", options: .regularExpression)
        let label = #"(?:official\s+)?(?:music\s+video|lyric\s+video|video|audio|lyrics|visuali[sz]er)|hd|4k|1080p"#
        for _ in 0..<3 {
            title = title.replacingOccurrences(of: "(?i)\\s*[\\(\\[]\\s*(?:\(label))\\s*[\\)\\]]\\s*$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)\\s*[-–—|]\\s*(?:\(label))\\s*$", with: "", options: .regularExpression)
        }
        let browser = ["com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac"]
            .contains { (bundleIdentifier ?? "").hasPrefix($0) }
        if let separator = title.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            let prefix = Self.trim(String(title[..<separator.lowerBound]))
            let suffix = Self.trim(String(title[separator.upperBound...]))
            let version = suffix.range(of: #"(?i)\b(live|remix|remaster\w*|edit|version|instrumental|acoustic|sped|slowed)\b"#, options: .regularExpression) != nil
            if !prefix.isEmpty, !suffix.isEmpty, !version,
               browser || artist.isEmpty || Self.key(prefix) == Self.key(artist) || title != original {
                artist = prefix
                title = suffix
            }
        }
        self.title = Self.trim(title).isEmpty ? original : Self.trim(title)
        self.artist = Self.trim(artist)
        self.album = Self.trim(album)
        self.duration = duration.isFinite && duration > 0 ? min(duration, 86400) : 0
    }

    func searchURL(includeArtist: Bool) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: title)]
        if includeArtist, !artist.isEmpty { components.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        // A literal plus in a song name must not become a form-encoded space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    func bestMatch(in results: [[String: Any]]) -> [String: Any]? {
        let candidates = results.filter { row in
            guard Self.key(row["trackName"] as? String ?? "") == Self.key(title) else { return false }
            let candidateArtist = Self.key(row["artistName"] as? String ?? "")
            let requestedArtist = Self.key(artist)
            let credits = (row["artistName"] as? String ?? "")
                .replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring|with|and)\s+|\s*[,;&]\s*"#,
                                      with: "\u{001F}", options: .regularExpression)
                .components(separatedBy: "\u{001F}").map(Self.key)
            guard requestedArtist.isEmpty || candidateArtist == requestedArtist
                || credits.contains(requestedArtist) else { return false }
            let length = row["duration"] as? Double ?? 0
            guard duration == 0 || length <= 0 || abs(length - duration) <= max(4, min(12, duration * 0.03)) else { return false }
            return !Self.trim(row["syncedLyrics"] as? String ?? "").isEmpty
                || !Self.trim(row["plainLyrics"] as? String ?? "").isEmpty
        }
        // A bare title shared by different artists is not a safe song match.
        if artist.isEmpty, Set(candidates.map { Self.key($0["artistName"] as? String ?? "") }).count > 1 { return nil }
        func score(_ row: [String: Any]) -> Double {
            let synced = Self.trim(row["syncedLyrics"] as? String ?? "")
            let distance = duration > 0 ? abs((row["duration"] as? Double ?? 0) - duration) : 0
            return (synced.isEmpty ? 0 : 100) + (Self.key(row["artistName"] as? String ?? "") == Self.key(artist) ? 20 : 0)
                + (Self.key(row["albumName"] as? String ?? "") == Self.key(album) ? 5 : 0) - min(15, distance)
        }
        return candidates.max { score($0) < score($1) }
    }

    private static func trim(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{FFFD}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func key(_ value: String) -> String {
        trim(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
