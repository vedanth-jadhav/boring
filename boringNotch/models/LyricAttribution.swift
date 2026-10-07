import Foundation

struct LyricAttribution: Codable, Equatable {
    struct Credit: Codable, Equatable {
        let name: String
        let url: URL?
    }

    let provider: String
    let providerURL: URL
    let credits: [Credit]

    init(source: String, upload: [String: Any]?) {
        switch source {
        case "apple_music":
            provider = "Apple Music"
            providerURL = URL(string: "https://music.apple.com")!
        case "spotify":
            provider = "Spotify"
            providerURL = URL(string: "https://open.spotify.com")!
        default:
            provider = "Spicy Lyrics"
            providerURL = URL(string: "https://spicylyrics.org")!
        }
        credits = source == "spicy_lyrics" ? ["Uploader", "Maker"].compactMap { role in
            guard let person = upload?[role] as? [String: Any],
                  let name = person["username"] as? String, !name.isEmpty else { return nil }
            let url = (person["url"] as? String).flatMap(URL.init(string:)).flatMap {
                $0.scheme == "https" && $0.host == "spicylyrics.org" ? $0 : nil
            }
            return Credit(name: name.replacingOccurrences(of: "\n", with: " "), url: url)
        } : []
    }
}
