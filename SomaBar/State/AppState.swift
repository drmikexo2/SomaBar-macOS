import SwiftUI
import os

private let log = Logger(subsystem: "com.somabar", category: "AppState")

/// One-shot gate between launch bootstrap and update recovery. Loading channel
/// and station data continues normally while suppressed; only the automatic
/// request to start the saved station is deferred. An explicit play discards
/// that deferred request because the user's newer choice wins.
struct AutomaticPlaybackRestorePolicy {
    private(set) var isSuppressed: Bool
    private(set) var restoreWasDeferred = false

    init(isSuppressed: Bool = false) {
        self.isSuppressed = isSuppressed
    }

    mutating func requestRestore() -> Bool {
        guard !isSuppressed else {
            restoreWasDeferred = true
            return false
        }
        return true
    }

    mutating func suppress() {
        isSuppressed = true
    }

    mutating func noteExplicitPlayback() {
        restoreWasDeferred = false
    }

    /// Returns true when releasing the gate should perform the deferred
    /// automatic restore now.
    mutating func release() -> Bool {
        isSuppressed = false
        guard restoreWasDeferred else { return false }
        restoreWasDeferred = false
        return true
    }
}

@Observable
@MainActor
final class AppState {
    // Internal (not private) so the topic extensions in AppState+*.swift can
    // reach it; nothing outside AppState's files should touch it.
    var didBootstrap = false

    // Channels
    var channels: [Channel] = []
    var channelsLoaded = false

    // Favorites — the persisted set is the single source of truth (no server).
    var favoriteIds: Set<String> = []

    // Stations unfavorited this session stay visible in the Favorites section
    // (with an outline star) so they're easy to re-favorite. Resets on relaunch.
    var sessionUnfavorited: Set<String> = []

    // Search
    var searchText: String = ""

    // Recently played stations, most recent first
    let recentStationsStore = RecentStationsStore()
    var recentStations: [RecentStation] { recentStationsStore.entries }

    // Playback
    let audioPlayer = AudioPlayer()
    @ObservationIgnored private var automaticPlaybackRestorePolicy: AutomaticPlaybackRestorePolicy

    // Listening history
    let historyRecorder: HistoryRecorder

    // Scrobbling
    let scrobbler: Scrobbler

    // Track-change notifications
    let trackNotifier: TrackNotifier
    /// Shown under the Settings row when macOS denied notification permission.
    var notifyPermissionHint: String?
    var notifyTrackChanges: Bool = Prefs.bool(.notifyTrackChanges, default: false) {
        didSet {
            Prefs.set(notifyTrackChanges, for: .notifyTrackChanges)
            trackNotifier.setEnabled(notifyTrackChanges)
            guard notifyTrackChanges else { return }
            notifyPermissionHint = nil
            Task { [weak self] in
                guard let self, await !self.trackNotifier.requestAuthorization() else { return }
                self.notifyTrackChanges = false
                self.notifyPermissionHint = "Enable SomaBar in System Settings → Notifications"
            }
        }
    }
    /// Banner after a hotkey-driven channel switch — the feedback that
    /// makes switching without the popover open usable. Default ON.
    var notifySwitchChanges: Bool = Prefs.bool(.notifyChannelSwitch, default: true) {
        didSet {
            Prefs.set(notifySwitchChanges, for: .notifyChannelSwitch)
            guard notifySwitchChanges else { return }
            notifyPermissionHint = nil
            Task { [weak self] in
                guard let self, await !self.trackNotifier.requestAuthorization() else { return }
                self.notifySwitchChanges = false
                self.notifyPermissionHint = "Enable SomaBar in System Settings → Notifications"
            }
        }
    }

    // Output device routing
    let deviceManager = AudioDeviceManager()
    /// The user's chosen device UID; kept even while the device is absent so
    /// the route re-applies when it comes back.
    var outputDeviceUID: String? = Prefs.string(.outputDeviceUID)

    func setOutputDevice(uid: String?) {
        outputDeviceUID = uid
        Prefs.set(uid, for: .outputDeviceUID)
        applyOutputDevice()
    }

    private func applyOutputDevice() {
        let available = outputDeviceUID.map { uid in
            deviceManager.devices.contains { $0.uid == uid }
        } ?? false
        audioPlayer.setOutputDevice(uid: available ? outputDeviceUID : nil)
    }

    // Global hotkeys — default on.
    private let hotkeyManager = HotkeyManager()
    var globalHotkeysEnabled: Bool = Prefs.bool(.globalHotkeys, default: true) {
        didSet {
            Prefs.set(globalHotkeysEnabled, for: .globalHotkeys)
            hotkeyManager.setEnabled(globalHotkeysEnabled)
        }
    }

    // Sleep timer — session-only; never persisted across launches
    let sleepTimer = SleepTimer()
    var sleepTimerEndDate: Date? { sleepTimer.endDate }
    var sleepTimerQuitsApp: Bool = Prefs.bool(.sleepTimerQuits, default: false) {
        didSet { Prefs.set(sleepTimerQuitsApp, for: .sleepTimerQuits) }
    }

    // Settings
    var selectedQuality: StreamQuality =
        StreamQuality.fromStored(Prefs.string(.quality)) ?? .best

    // UI
    var isLoading: Bool = false
    var errorMessage: String?
    var searchFieldFocused: Bool = false
    var artworkExpanded: Bool = false
    // Menu bar label components. All default ON.
    var menuBarShowPlayState: Bool = Prefs.bool(.menuBarShowPlayState, default: true) {
        didSet { Prefs.set(menuBarShowPlayState, for: .menuBarShowPlayState) }
    }
    var menuBarShowStation: Bool = Prefs.bool(.menuBarShowStation, default: true) {
        didSet { Prefs.set(menuBarShowStation, for: .menuBarShowStation) }
    }
    var menuBarShowArtist: Bool = Prefs.bool(.menuBarShowArtist, default: true) {
        didSet { Prefs.set(menuBarShowArtist, for: .menuBarShowArtist) }
    }
    var menuBarShowSong: Bool = Prefs.bool(.menuBarShowSong, default: true) {
        didSet { Prefs.set(menuBarShowSong, for: .menuBarShowSong) }
    }

    // MARK: - Computed

    var filteredChannels: [Channel] {
        Self.filteredChannels(channels: channels, searchText: searchText)
    }

    /// Pure so tests can exercise the sort/filter directly.
    static func filteredChannels(channels: [Channel], searchText: String) -> [Channel] {
        let sorted = channels.sorted(by: Self.channelOrder)
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Alphabetical by channel name.
    static func channelOrder(_ lhs: Channel, _ rhs: Channel) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    // MARK: - Lifecycle

    init(suppressAutomaticPlaybackRestore: Bool = false) {
        automaticPlaybackRestorePolicy = AutomaticPlaybackRestorePolicy(
            isSuppressed: suppressAutomaticPlaybackRestore
        )
        historyRecorder = HistoryRecorder(player: audioPlayer)
        trackNotifier = TrackNotifier(player: audioPlayer)
        scrobbler = Scrobbler(recorder: historyRecorder)
        historyRecorder.setEnabled(true)
        historyRecorder.start()
        historyRecorder.onTrackStarted = { [weak self] artist, title, duration in
            self?.scrobbler.trackStarted(artist: artist, title: title, duration: duration)
        }
        historyRecorder.onSegmentClosed = { [weak self] artist, title, duration, startedAt, endedAt, reason in
            self?.scrobbler.segmentClosed(
                artist: artist, title: title, duration: duration,
                startedAt: startedAt, endedAt: endedAt, reason: reason
            )
        }
        scrobbler.start()
        trackNotifier.setEnabled(notifyTrackChanges)
        trackNotifier.start()
        // Ask for notification permission up front — a deliberate first-launch
        // moment instead of a prompt buried under a hotkey press.
        if notifySwitchChanges || notifyTrackChanges {
            Task { [weak self] in
                guard let self, await !self.trackNotifier.requestAuthorization() else { return }
                self.notifySwitchChanges = false
                self.notifyTrackChanges = false
                self.notifyPermissionHint = "Enable SomaBar in System Settings → Notifications"
            }
        }
        audioPlayer.onNextTrack = { [weak self] in self?.cycleToNextFavorite() }
        audioPlayer.onPreviousTrack = { [weak self] in self?.cycleToPreviousFavorite() }
        hotkeyManager.onAction = { [weak self] action in
            log.info("hotkey action: \(String(describing: action), privacy: .public)")
            switch action {
            case .playPause: self?.togglePlayPause()
            case .nextFavorite: self?.cycleToNextFavorite()
            case .previousFavorite: self?.cycleToPreviousFavorite()
            }
        }
        hotkeyManager.setEnabled(globalHotkeysEnabled)
        sleepTimer.onFire = { [weak self] in
            guard let self else { return }
            self.audioPlayer.pause()
            if self.sleepTimerQuitsApp {
                NSApp.terminate(nil)
            }
        }
        deviceManager.onDevicesChanged = { [weak self] in
            self?.applyOutputDevice()
        }
        applyOutputDevice()
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    /// Launch bootstrap — no accounts, so the app is usable immediately.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        recentStationsStore.load()
        loadFavorites()
        await loadChannels(restoreStation: true)
    }

    // MARK: - Data Loading

    func loadChannels(restoreStation: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await SomaClient.fetchChannels()
            channels = fetched
            channelsLoaded = true
            log.info("loadChannels: \(fetched.count) channels loaded")

            // Only auto-resume the saved station at app launch.
            if restoreStation {
                restoreSavedStationIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
            log.error("loadChannels error: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback

    func playChannel(_ channel: Channel) {
        automaticPlaybackRestorePolicy.noteExplicitPlayback()
        startPlayback(channel)
    }

    private func startPlayback(_ channel: Channel) {
        Prefs.set(channel.id, for: .lastStationId)
        recentStationsStore.record(channel)
        let quality = selectedQuality
        log.info("playChannel: \(channel.name, privacy: .public) at \(quality.rawValue, privacy: .public)")
        Task { [weak self] in
            do {
                let stream = try await SomaClient.resolveStream(channel: channel, quality: quality)
                self?.audioPlayer.play(channel: channel, stream: stream)
            } catch {
                self?.errorMessage = error.localizedDescription
                log.error("playChannel resolve failed: \(error.localizedDescription)")
            }
        }
    }

    /// Prevent launch bootstrap from starting the saved station while an
    /// already-staged update is being recovered.
    func suppressAutomaticPlaybackRestore() {
        automaticPlaybackRestorePolicy.suppress()
    }

    /// Release a recovery gate. If bootstrap reached the restore point while
    /// suppressed, perform it once now unless explicit playback superseded it.
    func releaseAutomaticPlaybackRestore() {
        guard automaticPlaybackRestorePolicy.release() else { return }
        restoreSavedStationIfNeeded()
    }

    /// Hotkey actions: jump to the next/previous favorite (alphabetical,
    /// wrapping).
    func cycleToNextFavorite() { cycleFavorite(offset: 1) }
    func cycleToPreviousFavorite() { cycleFavorite(offset: -1) }

    private func cycleFavorite(offset: Int) {
        let favorites = channels
            .filter { favoriteIds.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !favorites.isEmpty else { return }
        let count = favorites.count
        let base: Int
        if let current = favorites.firstIndex(where: { $0.id == audioPlayer.currentChannel?.id }) {
            base = current + offset
        } else {
            // Idle: forward starts at the first favorite, back at the last
            base = offset > 0 ? 0 : count - 1
        }
        playChannel(favorites[((base % count) + count) % count])
        announceSwitchIfEnabled()
    }

    // No authorization round-trip here: permission is ensured at launch and on
    // toggle-on, and a transient failure must never silently kill the feature.
    private func announceSwitchIfEnabled() {
        guard notifySwitchChanges || notifyTrackChanges else { return }
        trackNotifier.announceSwitch()
    }

    // MARK: - Recently Played Stations

    /// Plays a recent entry. Stale entries (station gone from the channel
    /// list) self-heal by dropping out.
    func playRecentStation(_ entry: RecentStation) {
        guard let channel = channels.first(where: { $0.id == entry.channelId }) else {
            log.warning("playRecentStation: '\(entry.name, privacy: .public)' no longer available")
            recentStationsStore.remove(id: entry.id)
            return
        }
        playChannel(channel)
    }

    // MARK: - Song Votes

    /// The user's local vote on the current track (+1 / -1), nil when unvoted.
    var currentTrackVote: Int?

    func refreshCurrentTrackVote() {
        guard let track = audioPlayer.currentTrack,
              let songKey = TrackMatching.songKey(artist: track.artist, title: track.title)
        else {
            currentTrackVote = nil
            return
        }
        currentTrackVote = historyRecorder.vote(forSongKey: songKey)
    }

    /// Votes are local-only — SomaFM has no voting API. Keyed on the
    /// normalized artist|title, since there are no track ids either.
    func voteCurrentTrack(up: Bool) {
        guard let track = audioPlayer.currentTrack,
              let channel = audioPlayer.currentChannel,
              let songKey = TrackMatching.songKey(artist: track.artist, title: track.title)
        else { return }

        let newVote = up ? 1 : -1
        if historyRecorder.vote(forSongKey: songKey) == newVote {
            // Tapping the same thumb again removes the vote
            historyRecorder.clearVote(songKey: songKey)
            currentTrackVote = nil
        } else {
            historyRecorder.recordVote(
                songKey: songKey, vote: newVote,
                artist: track.artist, title: track.title,
                channelId: channel.id, channelName: channel.name,
                artPath: TrackArt.storagePath(from: track.artURL)
            )
            currentTrackVote = newVote
        }
    }

    func restartStreamForQualityChange() {
        guard audioPlayer.isPlaying,
              let channel = audioPlayer.currentChannel
        else { return }
        log.info("restartStreamForQualityChange: \(channel.name, privacy: .public) at \(self.selectedQuality.rawValue)")
        startPlayback(channel)
    }

    func togglePlayPause() {
        audioPlayer.togglePlayPause()
    }

    // MARK: - Sleep Timer

    func startSleepTimer(minutes: Int) {
        sleepTimer.start(minutes: minutes)
    }

    func cancelSleepTimer() {
        sleepTimer.cancel()
    }

    private func restoreSavedStationIfNeeded() {
        guard audioPlayer.currentChannel == nil else { return }
        guard automaticPlaybackRestorePolicy.requestRestore() else {
            log.info("restoreSavedStationIfNeeded: deferred for pending update")
            return
        }
        guard let channelId = Prefs.string(.lastStationId) else { return }
        guard let channel = channels.first(where: { $0.id == channelId }) else {
            log.warning("restoreSavedStationIfNeeded: saved station '\(channelId, privacy: .public)' not found")
            return
        }

        log.info("restoreSavedStationIfNeeded: restoring '\(channel.name, privacy: .public)'")
        startPlayback(channel)
    }
}
