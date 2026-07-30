import XCTest
@testable import SomaBar

final class ModelsTests: XCTestCase {
    // MARK: - NowPlaying.formatTime

    func testFormatTime() {
        XCTAssertEqual(NowPlaying.formatTime(0), "0:00")
        XCTAssertEqual(NowPlaying.formatTime(5), "0:05")
        XCTAssertEqual(NowPlaying.formatTime(65), "1:05")
        XCTAssertEqual(NowPlaying.formatTime(600), "10:00")
    }

    // MARK: - TrackArt (URL passthrough)

    func testStoragePathIsFullURL() {
        let url = URL(string: "https://api.somafm.com/logos/256/groovesalad256.png")!
        XCTAssertEqual(TrackArt.storagePath(from: url), url.absoluteString)
    }

    func testUrlFromStoredRoundTrips() {
        let original = URL(string: "https://api.somafm.com/logos/256/groovesalad256.png")!
        XCTAssertEqual(TrackArt.url(fromStored: TrackArt.storagePath(from: original)), original)
    }

    func testUrlFromStoredEmptyIsNil() {
        XCTAssertNil(TrackArt.url(fromStored: nil))
        XCTAssertNil(TrackArt.url(fromStored: ""))
    }

    // MARK: - Channel decoding (channels.json)

    /// Trimmed from the live feed. The critical quirk: every scalar is a JSON
    /// string, including listeners and updated.
    private static let channelJSON = Data("""
    {"channels": [
      {
        "id": "groovesalad",
        "title": "Groove Salad",
        "description": "A nicely chilled plate of ambient/downtempo beats and grooves.",
        "dj": "Rusty Hodge",
        "djmail": "rusty@somafm.com",
        "genre": "ambient|electronic",
        "image": "https://api.somafm.com/logos/120/groovesalad120.png",
        "largeimage": "https://api.somafm.com/logos/256/groovesalad256.png",
        "xlimage": "https://api.somafm.com/logos/512/groovesalad512.png",
        "twitter": "",
        "updated": "1780812672",
        "playlists": [
          { "url": "https://api.somafm.com/groovesalad256.pls", "format": "mp3", "quality": "highest" },
          { "url": "https://api.somafm.com/groovesalad130.pls", "format": "aac", "quality": "highest" },
          { "url": "https://api.somafm.com/groovesalad64.pls", "format": "aacp", "quality": "high" },
          { "url": "https://api.somafm.com/groovesalad32.pls", "format": "aacp", "quality": "low" }
        ],
        "preroll": [],
        "listeners": "1971",
        "lastPlaying": "Thomas Lemmer & Andreas Bach - Deep Ocean"
      },
      {
        "id": "minimal",
        "title": "Minimal Channel",
        "description": "",
        "dj": "",
        "djmail": "",
        "genre": "ambient",
        "image": "https://api.somafm.com/logos/120/minimal120.jpg",
        "largeimage": "",
        "xlimage": "",
        "twitter": "",
        "updated": "1674955401",
        "playlists": [
          { "url": "https://api.somafm.com/minimal.pls", "format": "mp3", "quality": "highest" }
        ],
        "preroll": [],
        "listeners": "0",
        "lastPlaying": "",
        "featured": "2"
      }
    ]}
    """.utf8)

    func testChannelDecodingHandlesStringScalars() throws {
        let decoded = try JSONDecoder().decode(ChannelsResponse.self, from: Self.channelJSON)
        XCTAssertEqual(decoded.channels.count, 2)

        let groove = decoded.channels[0]
        XCTAssertEqual(groove.id, "groovesalad")
        XCTAssertEqual(groove.name, "Groove Salad")
        XCTAssertEqual(groove.key, "groovesalad")
        XCTAssertEqual(groove.listenerCount, 1971)
        XCTAssertEqual(groove.genres, ["ambient", "electronic"])
        XCTAssertEqual(groove.playlists.count, 4)
        XCTAssertEqual(groove.playlists[0].format, "mp3")
        XCTAssertEqual(groove.playlists[0].quality, "highest")
    }

    func testChannelLogoURLPrefersLargeImage() throws {
        let decoded = try JSONDecoder().decode(ChannelsResponse.self, from: Self.channelJSON)
        XCTAssertEqual(
            decoded.channels[0].logoURL?.absoluteString,
            "https://api.somafm.com/logos/256/groovesalad256.png"
        )
        XCTAssertEqual(
            decoded.channels[0].xlLogoURL?.absoluteString,
            "https://api.somafm.com/logos/512/groovesalad512.png"
        )
    }

    func testChannelLogoURLFallsBackWhenLargerSizesEmpty() throws {
        let decoded = try JSONDecoder().decode(ChannelsResponse.self, from: Self.channelJSON)
        // largeimage/xlimage are "" — empty strings make no URL, so the
        // 120px image is the fallback.
        XCTAssertEqual(
            decoded.channels[1].logoURL?.absoluteString,
            "https://api.somafm.com/logos/120/minimal120.jpg"
        )
    }

    func testChannelEqualityIsById() throws {
        let decoded = try JSONDecoder().decode(ChannelsResponse.self, from: Self.channelJSON)
        XCTAssertEqual(decoded.channels[0], decoded.channels[0])
        XCTAssertNotEqual(decoded.channels[0], decoded.channels[1])
    }

    // MARK: - Songs decoding (songs/{id}.json)

    func testSongsResponseDecoding() throws {
        let json = Data("""
        {"id": "groovesalad", "songs": [
          {"title": "From Zen To Fit", "artist": "Trestal", "album": "Chillville",
           "albumArt": "", "date": "1785444534"},
          {"title": "Dope", "artist": "Kruder & Dorfmeister", "album": "",
           "albumArt": "", "date": "1785442911"}
        ]}
        """.utf8)
        let decoded = try JSONDecoder().decode(SongsResponse.self, from: json)
        XCTAssertEqual(decoded.songs.count, 2)
        XCTAssertEqual(decoded.songs[0].artist, "Trestal")
        XCTAssertEqual(decoded.songs[0].album, "Chillville")
        XCTAssertEqual(decoded.songs[0].date, "1785444534")
    }

    // MARK: - StreamQuality

    func testStreamQualityMatchesPlaylists() {
        let mp3 = Channel.Playlist(url: "https://api.somafm.com/x256.pls", format: "mp3", quality: "highest")
        let aac = Channel.Playlist(url: "https://api.somafm.com/x130.pls", format: "aac", quality: "highest")
        let aacpHigh = Channel.Playlist(url: "https://api.somafm.com/x64.pls", format: "aacp", quality: "high")
        let aacpLow = Channel.Playlist(url: "https://api.somafm.com/x32.pls", format: "aacp", quality: "low")

        XCTAssertTrue(StreamQuality.mp3Highest.matches(mp3))
        XCTAssertTrue(StreamQuality.aacHighest.matches(aac))
        XCTAssertTrue(StreamQuality.aacpHigh.matches(aacpHigh))
        XCTAssertTrue(StreamQuality.aacpLow.matches(aacpLow))
        XCTAssertFalse(StreamQuality.mp3Highest.matches(aac))
        XCTAssertFalse(StreamQuality.aacHighest.matches(aacpHigh))
    }
}
