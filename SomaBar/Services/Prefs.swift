import Foundation

/// App settings, stored in UserDefaults.
///
/// Booleans are stored as "1"/"0" strings (the historical format). Keys live
/// in the `Key` registry so a typo can't silently orphan a setting.
enum Prefs {
    private static let prefix = "com.somabar."

    /// Every key the app stores.
    enum Key: String {
        case lastStationId = "last_station_id"
        case favoriteStationIds = "favorite_station_ids"
        case recentStations = "recent_stations"
        case quality
        case notifyTrackChanges = "notify_track_changes"
        case notifyChannelSwitch = "notify_channel_switch"
        case outputDeviceUID = "output_device_uid"
        case globalHotkeys = "global_hotkeys"
        case sleepTimerQuits = "sleep_timer_quits"
        case menuBarShowPlayState = "menubar_show_playstate"
        case menuBarShowStation = "menubar_show_station"
        case menuBarShowArtist = "menubar_show_artist"
        case menuBarShowSong = "menubar_show_song"
        case allStationsExpanded = "all_stations_expanded"
        case recentStationsExpanded = "recent_stations_expanded"
        case sleepTimerCustomMinutes = "sleep_timer_custom_minutes"
        case lastFMSessionKey = "lastfm_session_key"
        case lastFMUsername = "lastfm_username"
        case pendingUpdateVersion = "pending_update_version"
        case pendingUpdateBuild = "pending_update_build"
        case pendingUpdateAttempts = "pending_update_attempts"
    }

    // MARK: - Typed accessors

    static func string(_ key: Key) -> String? {
        read(key: key.rawValue)
    }

    static func set(_ value: String?, for key: Key) {
        if let value {
            save(key: key.rawValue, value: value)
        } else {
            delete(key: key.rawValue)
        }
    }

    /// Booleans store as "1"/"0"; a missing key yields `default`.
    static func bool(_ key: Key, default defaultValue: Bool) -> Bool {
        guard let raw = read(key: key.rawValue) else { return defaultValue }
        return raw != "0"
    }

    static func set(_ value: Bool, for key: Key) {
        save(key: key.rawValue, value: value ? "1" : "0")
    }

    static func int(_ key: Key) -> Int? {
        read(key: key.rawValue).flatMap(Int.init)
    }

    static func set(_ value: Int, for key: Key) {
        save(key: key.rawValue, value: String(value))
    }

    /// String sets store comma-joined; channel slugs never contain commas.
    static func stringSet(_ key: Key) -> Set<String> {
        Set((read(key: key.rawValue) ?? "")
            .split(separator: ",")
            .map(String.init))
    }

    static func set(_ value: Set<String>, for key: Key) {
        save(key: key.rawValue, value: value.sorted().joined(separator: ","))
    }

    // MARK: - Raw storage

    private static func save(key: String, value: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    private static func read(key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    private static func delete(key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }
}
