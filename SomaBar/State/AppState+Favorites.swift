import Foundation
import os

private let log = Logger(subsystem: "com.somabar", category: "AppState")

/// Favorites: purely local — SomaFM has no accounts, so the persisted set in
/// Prefs is the single source of truth.
extension AppState {
    var favoriteChannels: [Channel] {
        let visible = favoriteIds.union(sessionUnfavorited)
        return channels
            .filter { visible.contains($0.id) }
            .sorted(by: Self.channelOrder)
    }

    func loadFavorites() {
        favoriteIds = Prefs.stringSet(.favoriteStationIds)
    }

    func toggleFavorite(_ channel: Channel) {
        toggleFavorite(channelId: channel.id, name: channel.name)
    }

    /// Id-based variant for rows that don't hold a full Channel (recents).
    func toggleFavorite(channelId: String, name: String) {
        let adding = !favoriteIds.contains(channelId)
        if adding {
            favoriteIds.insert(channelId)
            sessionUnfavorited.remove(channelId)
        } else {
            favoriteIds.remove(channelId)
            sessionUnfavorited.insert(channelId)
        }
        Prefs.set(favoriteIds, for: .favoriteStationIds)
        log.info("toggleFavorite: \(adding ? "add" : "remove") \(name, privacy: .public)")
    }
}
