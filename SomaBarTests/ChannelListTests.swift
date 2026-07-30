import XCTest
@testable import SomaBar

// AppState is @MainActor, so its statics are too.
@MainActor
final class ChannelListTests: XCTestCase {
    private func channel(id: String, name: String) -> Channel {
        Channel(
            id: id, title: name, description: nil, dj: nil, genre: nil,
            image: nil, largeimage: nil, xlimage: nil,
            listeners: nil, lastPlaying: nil, playlists: []
        )
    }

    private var channels: [Channel] {
        [
            channel(id: "chillout", name: "Chillout"),
            channel(id: "ambient", name: "Ambient"),
            channel(id: "sleep", name: "Sleep"),
        ]
    }

    // MARK: - Channel list

    func testFilteredChannelsSortsByName() {
        let sorted = AppState.filteredChannels(channels: channels, searchText: "")
        XCTAssertEqual(sorted.map(\.name), ["Ambient", "Chillout", "Sleep"])
    }

    func testSearchFiltersList() {
        let filtered = AppState.filteredChannels(channels: channels, searchText: "chill")
        XCTAssertEqual(filtered.map(\.name), ["Chillout"])
    }

    func testSearchIsCaseInsensitive() {
        let filtered = AppState.filteredChannels(channels: channels, searchText: "AMBIENT")
        XCTAssertEqual(filtered.map(\.name), ["Ambient"])
    }

    // MARK: - RecentStation id

    func testRecentStationIdIsChannelId() {
        let recent = RecentStation(channelId: "groovesalad", name: "Groove Salad")
        XCTAssertEqual(recent.id, "groovesalad")
    }

    // MARK: - Favorite toggling (id-based overload)

    // Favorites persist in Prefs — snapshot and restore around the test.
    func testToggleFavoriteByIdMatchesChannelOverload() {
        let saved = Prefs.stringSet(.favoriteStationIds)
        defer { Prefs.set(saved, for: .favoriteStationIds) }

        let state = AppState()
        let ch = channel(id: "teststation", name: "Test Station")

        state.toggleFavorite(channelId: ch.id, name: ch.name)
        XCTAssertTrue(state.favoriteIds.contains(ch.id))
        XCTAssertTrue(Prefs.stringSet(.favoriteStationIds).contains(ch.id))

        // The Channel overload must undo the id-based toggle symmetrically
        state.toggleFavorite(ch)
        XCTAssertFalse(state.favoriteIds.contains(ch.id))
        XCTAssertFalse(Prefs.stringSet(.favoriteStationIds).contains(ch.id))
        XCTAssertTrue(state.sessionUnfavorited.contains(ch.id))
    }

    // MARK: - Playing station reveal

    func testPlayingRevealResolvesFromChannelId() {
        let request = PlayingRevealRequest.resolve(channelID: "groovesalad")
        XCTAssertEqual(request?.channelID, "groovesalad")
        XCTAssertEqual(request?.itemID, "groovesalad")
    }

    func testPlayingRevealNeedsAChannel() {
        XCTAssertNil(PlayingRevealRequest.resolve(channelID: nil))
    }
}
