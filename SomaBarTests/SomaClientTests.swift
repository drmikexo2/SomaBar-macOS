import XCTest
@testable import SomaBar

final class SomaClientTests: XCTestCase {
    // MARK: - parsePLS

    private let samplePLS = """
    [playlist]
    numberofentries=3
    File1=https://ice6.somafm.com/groovesalad-128-mp3
    Title1=SomaFM: Groove Salad (#1)
    Length1=-1
    File2=https://ice2.somafm.com/groovesalad-128-mp3
    Title2=SomaFM: Groove Salad (#2)
    Length2=-1
    File3=https://ice5.somafm.com/groovesalad-128-mp3
    Title3=SomaFM: Groove Salad (#3)
    Length3=-1
    Version=2
    """

    func testParsePLSExtractsServersInOrder() {
        let servers = SomaClient.parsePLS(samplePLS)
        XCTAssertEqual(servers.map(\.absoluteString), [
            "https://ice6.somafm.com/groovesalad-128-mp3",
            "https://ice2.somafm.com/groovesalad-128-mp3",
            "https://ice5.somafm.com/groovesalad-128-mp3",
        ])
    }

    func testParsePLSOrdersByFileNumberNotAppearance() {
        let shuffled = """
        [playlist]
        File2=https://ice2.somafm.com/b
        File1=https://ice6.somafm.com/a
        File3=https://ice5.somafm.com/c
        """
        let servers = SomaClient.parsePLS(shuffled)
        XCTAssertEqual(servers.map(\.lastPathComponent), ["a", "b", "c"])
    }

    func testParsePLSForcesHTTPS() {
        let plaintext = """
        [playlist]
        File1=http://ice6.somafm.com/groovesalad-128-mp3
        """
        XCTAssertEqual(
            SomaClient.parsePLS(plaintext).first?.absoluteString,
            "https://ice6.somafm.com/groovesalad-128-mp3"
        )
    }

    func testParsePLSIgnoresMalformedAndForeignLines() {
        let junk = """
        [playlist]
        Title1=Not a file
        FileX=https://bad.example/nope
        File1
        File2=https://ice1.somafm.com/ok
        """
        XCTAssertEqual(
            SomaClient.parsePLS(junk).map(\.absoluteString),
            ["https://ice1.somafm.com/ok"]
        )
    }

    func testParsePLSEmptyInput() {
        XCTAssertEqual(SomaClient.parsePLS(""), [])
        XCTAssertEqual(SomaClient.parsePLS("[playlist]\nnumberofentries=0"), [])
    }

    // MARK: - Playlist selection

    private let fullPlaylists = [
        Channel.Playlist(url: "https://api.somafm.com/x256.pls", format: "mp3", quality: "highest"),
        Channel.Playlist(url: "https://api.somafm.com/x130.pls", format: "aac", quality: "highest"),
        Channel.Playlist(url: "https://api.somafm.com/x64.pls", format: "aacp", quality: "high"),
        Channel.Playlist(url: "https://api.somafm.com/x32.pls", format: "aacp", quality: "low"),
    ]

    func testPickPlaylistExactMatch() {
        XCTAssertEqual(
            SomaClient.pickPlaylist(from: fullPlaylists, quality: .aacHighest)?.url,
            "https://api.somafm.com/x130.pls"
        )
        XCTAssertEqual(
            SomaClient.pickPlaylist(from: fullPlaylists, quality: .mp3Highest)?.url,
            "https://api.somafm.com/x256.pls"
        )
    }

    func testPickPlaylistFallsBackDownTheTiers() {
        // Only the low tier exists — any requested quality lands on it.
        let lowOnly = [fullPlaylists[3]]
        XCTAssertEqual(
            SomaClient.pickPlaylist(from: lowOnly, quality: .mp3Highest)?.url,
            "https://api.somafm.com/x32.pls"
        )
    }

    func testPickPlaylistUnknownTiersFallBackToFirstEntry() {
        let exotic = [Channel.Playlist(url: "https://api.somafm.com/x.pls", format: "ogg", quality: "best")]
        XCTAssertEqual(
            SomaClient.pickPlaylist(from: exotic, quality: .aacHighest)?.url,
            "https://api.somafm.com/x.pls"
        )
    }

    func testPickPlaylistEmptyIsNil() {
        XCTAssertNil(SomaClient.pickPlaylist(from: [], quality: .aacHighest))
    }

    // MARK: - https forcing

    func testHTTPSURLForcesScheme() {
        XCTAssertEqual(
            SomaClient.httpsURL(from: "http://api.somafm.com/groovesalad.pls")?.absoluteString,
            "https://api.somafm.com/groovesalad.pls"
        )
        XCTAssertEqual(
            SomaClient.httpsURL(from: "https://api.somafm.com/groovesalad.pls")?.absoluteString,
            "https://api.somafm.com/groovesalad.pls"
        )
    }
}
