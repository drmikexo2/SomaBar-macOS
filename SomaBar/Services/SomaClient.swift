import Foundation
import os

private let log = Logger(subsystem: "com.somabar", category: "SomaClient")

enum SomaClientError: LocalizedError {
    case httpError(Int)
    case networkError(Error)
    case decodingError(Error)
    case invalidURL
    case emptyPlaylist

    var errorDescription: String? {
        switch self {
        case .httpError(let code): "Server error (\(code))"
        case .networkError(let err): "Network error: \(err.localizedDescription)"
        case .decodingError(let err): "Data error: \(err.localizedDescription)"
        case .invalidURL: "Invalid URL"
        case .emptyPlaylist: "Stream playlist is empty"
        }
    }
}

/// Client for SomaFM's public endpoints. SomaFM has no third-party API
/// program anymore, so this behaves as a polite guest: every request carries
/// an identifying User-Agent (their Icecast edge drops anonymous clients),
/// caching honors the server's short max-age headers, and nothing polls
/// faster than the feeds actually change.
enum SomaClient {
    static let userAgent: String = {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "SomaBar/\(version) (macOS; +https://github.com/drmikexo2/SomaBar-macOS)"
    }()

    /// Every SomaFM fetch goes through this so the User-Agent can't be missed.
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request(url))
        } catch {
            throw SomaClientError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SomaClientError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw SomaClientError.httpError(http.statusCode)
        }
        return data
    }

    // MARK: - Channels

    static func fetchChannels() async throws -> [Channel] {
        let data = try await fetch(SomaFM.channelsURL)
        do {
            let decoded = try JSONDecoder().decode(ChannelsResponse.self, from: data)
            log.info("channels: \(decoded.channels.count) channels, \(data.count) bytes")
            return decoded.channels
        } catch {
            throw SomaClientError.decodingError(error)
        }
    }

    // MARK: - Recent Songs

    /// The 17-entry rolling play history for a channel — the only source of
    /// album names (ICY titles carry artist/title only). URLSession's protocol
    /// cache policy revalidates with ETag/Last-Modified, so repeat fetches
    /// inside the server's max-age are free.
    static func fetchRecentSongs(channelId: String) async throws -> [SomaSong] {
        guard let url = SomaFM.songsURL(channelId: channelId) else {
            throw SomaClientError.invalidURL
        }
        let data = try await fetch(url)
        do {
            return try JSONDecoder().decode(SongsResponse.self, from: data).songs
        } catch {
            throw SomaClientError.decodingError(error)
        }
    }

    // MARK: - Stream Resolution

    /// Resolves a channel + quality to playable stream URLs by fetching and
    /// parsing the .pls playlist. The playlist URL comes from channels.json
    /// verbatim (the numeric filename suffixes aren't derivable from the
    /// channel id), and is forced to https — an http .pls returns http
    /// stream entries, which ATS would then block.
    ///
    /// `.best` resolves the mp3 tier first and keeps it only when it's the
    /// genuine high-bitrate stream; otherwise it re-resolves to 128k AAC —
    /// 128k MP3 is never served (worse than 128k AAC at the same bits).
    static func resolveStream(channel: Channel, quality: StreamQuality) async throws -> ResolvedStream {
        if quality == .best {
            if let mp3 = try? await resolveTier(channel: channel, tier: ("mp3", "highest")),
               bestPrefersMP3(mp3.streamInfo) {
                return mp3
            }
            return try await resolveTier(channel: channel, tier: ("aac", "highest"))
        }
        guard let tier = quality.tier else { throw SomaClientError.invalidURL }
        return try await resolveTier(channel: channel, tier: tier)
    }

    /// Whether the resolved mp3 tier is worth playing under `.best`: only
    /// the genuine 256/320k streams qualify. 128k, unparseable, or non-MP3
    /// all fall back to the known-good 128k AAC.
    static func bestPrefersMP3(_ info: ResolvedStream.StreamInfo?) -> Bool {
        guard let info else { return false }
        return info.codec == "MP3" && info.kbps >= 192
    }

    private static func resolveTier(
        channel: Channel, tier: (format: String, quality: String)
    ) async throws -> ResolvedStream {
        guard let playlist = pickPlaylist(from: channel.playlists, tier: tier),
              let playlistURL = httpsURL(from: playlist.url)
        else { throw SomaClientError.invalidURL }

        let data = try await fetch(playlistURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SomaClientError.emptyPlaylist
        }
        let servers = parsePLS(text)
        guard !servers.isEmpty else { throw SomaClientError.emptyPlaylist }
        log.info("resolveStream(\(channel.id)): \(playlistURL.lastPathComponent) -> \(servers.count) servers")
        return ResolvedStream(playlistURL: playlistURL, servers: servers)
    }

    /// First playlist matching the requested tier, else the nearest tier in
    /// preference order, else the feed's first entry.
    static func pickPlaylist(
        from playlists: [Channel.Playlist], tier: (format: String, quality: String)
    ) -> Channel.Playlist? {
        let ladder: [(format: String, quality: String)] = [
            tier, ("aac", "highest"), ("aacp", "high"), ("mp3", "highest"),
        ]
        for candidate in ladder {
            if let match = playlists.first(where: {
                $0.format == candidate.format && $0.quality == candidate.quality
            }) {
                return match
            }
        }
        return playlists.first
    }

    static func httpsURL(from urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// Parses a .pls playlist into its FileN entries, in numeric order.
    /// SomaFM playlists list 3 redundant ice servers; https is forced on
    /// each entry as a second guard.
    static func parsePLS(_ text: String) -> [URL] {
        var entries: [(index: Int, url: URL)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("file"),
                  let equals = trimmed.firstIndex(of: "=")
            else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard let index = Int(key.dropFirst("file".count)) else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let url = httpsURL(from: value) else { continue }
            entries.append((index, url))
        }
        return entries.sorted { $0.index < $1.index }.map(\.url)
    }
}
