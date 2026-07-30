import Foundation

// MARK: - Stream Quality

/// The quality setting is intent-based, not a raw SomaFM tier. SomaFM's mp3
/// "highest" tier varies per channel (128k on most, 256/320k on flagships)
/// and 128k MP3 is strictly worse than 128k AAC — so `.best` resolves
/// per-channel to the high-bitrate MP3 where it exists and 128k AAC
/// otherwise, and no setting can ever land on 128k MP3.
enum StreamQuality: String, CaseIterable, Identifiable, Codable {
    case best
    case aacHighest = "aac_highest"
    case aacpHigh = "aacp_high"

    var id: String { rawValue }

    /// Stored-pref reader with legacy migration: earlier builds stored the
    /// raw tiers "mp3_highest" (now the auto mode) and "aacp_low" (dropped).
    static func fromStored(_ raw: String?) -> StreamQuality? {
        guard let raw else { return nil }
        switch raw {
        case "mp3_highest": return .best
        case "aacp_low": return .aacpHigh
        default: return StreamQuality(rawValue: raw)
        }
    }

    /// Menu item label.
    var menuTitle: String {
        switch self {
        case .best: "High: 256k+ MP3 where available; otherwise 128k AAC"
        case .aacHighest: "Medium: 128k AAC"
        case .aacpHigh: "Data saver: 64k AAC"
        }
    }

    /// Collapsed picker label.
    var shortTitle: String {
        switch self {
        case .best: "High"
        case .aacHighest: "Medium"
        case .aacpHigh: "Data saver"
        }
    }

    /// The concrete channels.json playlist tier, nil for the auto mode
    /// (which decides after resolving what the mp3 tier actually serves).
    var tier: (format: String, quality: String)? {
        switch self {
        case .best: nil
        case .aacHighest: ("aac", "highest")
        case .aacpHigh: ("aacp", "high")
        }
    }
}

// MARK: - SomaFM constants

enum SomaFM {
    /// Stored in the history DB's network column; the schema keeps the
    /// dimension so rows stay self-describing.
    static let networkTag = "somafm"
    static let channelsURL = URL(string: "https://somafm.com/channels.json")!
    static let supportURL = URL(string: "https://somafm.com/support/")!
    static func songsURL(channelId: String) -> URL? {
        URL(string: "https://somafm.com/songs/\(channelId).json")
    }
}

// MARK: - Channel

/// One entry in the recently-played MRU list.
struct RecentStation: Codable, Identifiable, Equatable {
    let channelId: String
    let name: String

    var id: String { channelId }
}

/// One channel from channels.json. Every scalar in the feed is a JSON string,
/// including numbers ("listeners": "1971") — decode accordingly.
struct Channel: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let dj: String?
    /// Pipe-delimited multi-value ("ambient|electronic").
    let genre: String?
    let image: String?
    let largeimage: String?
    let xlimage: String?
    let listeners: String?
    let lastPlaying: String?
    let playlists: [Playlist]

    struct Playlist: Codable, Hashable {
        let url: String
        let format: String
        let quality: String
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, dj, genre
        case image, largeimage, xlimage
        case listeners, lastPlaying, playlists
    }

    /// Aliases keep call sites that predate the SomaFM port unchanged:
    /// `name` was the display name, `key` the stream identifier.
    var name: String { title }
    var key: String { id }

    var listenerCount: Int { listeners.flatMap(Int.init) ?? 0 }

    var genres: [String] {
        (genre ?? "").split(separator: "|").map(String.init)
    }

    /// 256px channel logo — the artwork size the panel displays.
    var logoURL: URL? {
        Self.firstURL(largeimage, xlimage, image)
    }

    /// 512px logo for notification attachments and expanded artwork.
    var xlLogoURL: URL? {
        Self.firstURL(xlimage, largeimage, image)
    }

    /// The feed uses "" rather than null for missing images.
    private static func firstURL(_ candidates: String?...) -> URL? {
        for candidate in candidates {
            if let candidate, !candidate.isEmpty, let url = URL(string: candidate) {
                return url
            }
        }
        return nil
    }

    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ChannelsResponse: Codable {
    let channels: [Channel]
}

// MARK: - Recent Songs (songs/{id}.json)

/// One entry of the 17-track rolling history. All values are strings;
/// `date` is Unix epoch seconds (start of play). `albumArt` is empty in
/// practice — the channel logo is the artwork.
struct SomaSong: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let albumArt: String?
    let date: String?
}

struct SongsResponse: Codable {
    let id: String?
    let songs: [SomaSong]
}

// MARK: - Resolved Stream

/// Output of the .pls resolution: the redundant ice servers in playlist
/// order. Servers are load-balancer assignments, not stable hosts — callers
/// re-resolve rather than caching across reconnect cycles.
struct ResolvedStream: Equatable {
    let playlistURL: URL
    let servers: [URL]

    /// The actual bitrate and codec being played, parsed from the server URL
    /// (`{channel}-{kbps}-{codec}`, e.g. "groovesalad-256-mp3"). This is the
    /// only honest source: the quality *tier* hides that SomaFM's MP3
    /// "highest" varies per channel (128k on most, 256/320k on flagships),
    /// and the .pls filename suffix lies (groovesalad130.pls serves 128k).
    struct StreamInfo: Equatable {
        let kbps: Int
        let codec: String

        var displayText: String { "\(kbps) kbps \(codec)" }
    }

    var streamInfo: StreamInfo? {
        guard let name = servers.first?.lastPathComponent else { return nil }
        let parts = name.split(separator: "-")
        guard parts.count >= 3, let kbps = Int(parts[parts.count - 2]) else { return nil }
        let codec: String
        switch parts.last?.lowercased() {
        case "mp3": codec = "MP3"
        case "aac", "aacp": codec = "AAC"
        default: return nil
        }
        return StreamInfo(kbps: kbps, codec: codec)
    }
}

// MARK: - Track / Now Playing

/// Shared display formatting for song metadata — the one place that decides
/// how "Artist – Title" joins and how durations render.
enum TrackDisplay {
    /// "Artist – Title" (en dash), degrading to whichever side is present.
    static func artistTitle(_ artist: String, _ title: String) -> String {
        if artist.isEmpty { return title }
        if title.isEmpty { return artist }
        return "\(artist) – \(title)"
    }

    /// "m:ss"
    static func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct NowPlaying: Equatable {
    let channelName: String
    let artist: String
    let title: String
    let album: String?
    let artURL: URL?
    let duration: Int
    let startedAt: Date?
    let elapsedOverride: Int?

    var displayText: String {
        if artist.isEmpty && title.isEmpty { return channelName }
        return TrackDisplay.artistTitle(artist, title)
    }

    /// Seconds into the track: the frozen override when the timing engine set
    /// one, else wall clock since the anchored start.
    func elapsedSeconds(at now: Date = Date()) -> Int? {
        if let elapsedOverride { return max(elapsedOverride, 0) }
        guard let startedAt else { return nil }
        return max(Int(now.timeIntervalSince(startedAt)), 0)
    }

    static func formatTime(_ seconds: Int) -> String {
        TrackDisplay.formatTime(seconds)
    }
}

/// Artwork is channel logos on SomaFM's own hosts, stored as full URLs.
/// (The AudioAddict-era CDN-relative storage and server-side thumbnailing
/// are gone; logos are small enough to use as-is.)
enum TrackArt {
    static func storagePath(from url: URL?) -> String? {
        url?.absoluteString
    }

    static func url(fromStored stored: String?) -> URL? {
        guard let stored, !stored.isEmpty else { return nil }
        return URL(string: stored)
    }
}
