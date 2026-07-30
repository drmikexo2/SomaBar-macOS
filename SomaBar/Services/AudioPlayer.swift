import AppKit
import AVFoundation
import MediaPlayer
import os

private let log = Logger(subsystem: "com.somabar", category: "AudioPlayer")

@Observable
@MainActor
final class AudioPlayer {
    /// What the transport is actually doing. `isPlaying` stays "the user wants
    /// playback" so state diffing in HistoryRecorder keeps working unchanged.
    enum PlaybackPhase: Equatable {
        case idle
        case buffering
        case playing
        case paused
        case reconnecting(attempt: Int)
        case failed
    }

    var isPlaying: Bool = false
    var volume: Float = 0.75
    /// Session-only, like volume: never persisted. `volume` keeps the user's
    /// level while muted (the implicit stash); only the AVPlayer is zeroed.
    var isMuted: Bool = false

    // ◀◀/▶▶ media-key actions, set by AppState (favorite-channel cycling)
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    var playbackError: String?
    var currentChannel: Channel?
    var currentTrack: NowPlaying?
    var currentArtImage: NSImage?
    var currentTrackIdentityToken: String?
    var phase: PlaybackPhase = .idle

    var isRecovering: Bool {
        if case .reconnecting = phase { return true }
        return false
    }

    /// True only while sound should actually be coming from the selected
    /// output. `isPlaying` remains the user's intent through buffering and
    /// reconnecting, so it is too broad for an animated audible indicator.
    var isAudiblyPlaying: Bool {
        phase == .playing && !isMuted
    }

    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var metadataDelegate: StreamMetadataDelegate?
    private var playbackSessionID = UUID()
    private var lastIcyStreamTitle: String?
    private var audibleStartedAt: Date?
    private var enrichmentTask: Task<Void, Never>?

    // Reconnect state. AVPlayer is handed the .pls playlist URL, not a direct
    // ice-server URL: AVFoundation's playlist path is the only one that
    // surfaces ICY timed metadata, and re-fetching the .pls on every restart
    // picks up fresh load-balancer server assignments for free.
    private var lastPlayArgs: (channel: Channel, stream: ResolvedStream)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var hasPlayedThisSession = false
    private var isReconnectRestart = false
    private var autoResumeOnNetworkReturn = false
    private var lastItemError: String?
    private var pausedAt: Date?
    private var pauseTeardownTimer: Timer?
    private var itemNotificationTokens: [NSObjectProtocol] = []
    private var recovery: PlaybackRecovery?
    private static let reconnectBackoff: [Double] = [1, 2, 4, 8, 15, 30, 30, 30]

    init() {
        setupRemoteCommands()
        recovery = PlaybackRecovery(player: self)
    }

    // MARK: - Playback

    /// Starts a channel from a resolved stream.
    func play(channel: Channel, stream: ResolvedStream) {
        // A user-initiated play resets recovery; a retry from the reconnect
        // loop must not cancel the loop that issued it.
        if !isReconnectRestart {
            cancelReconnect()
            reconnectAttempt = 0
            autoResumeOnNetworkReturn = false
        }
        lastPlayArgs = (channel, stream)
        hasPlayedThisSession = false
        pausedAt = nil
        pauseTeardownTimer?.invalidate()
        pauseTeardownTimer = nil
        startStream(channel: channel, stream: stream)
    }

    private func startStream(channel: Channel, stream: ResolvedStream) {
        enrichmentTask?.cancel()
        enrichmentTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        metadataDelegate = nil

        // Release old player item before loading new one
        player?.replaceCurrentItem(with: nil)

        if player == nil {
            player = AVPlayer()
            player?.volume = isMuted ? 0 : volume
            timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
                let status = observed.timeControlStatus
                Task { @MainActor [weak self] in
                    self?.handleTimeControlChange(status)
                }
            }
        }
        // Re-apply the chosen route on every (re)start so reconnects and
        // quality changes keep playing to the same device.
        player?.audioOutputDeviceUniqueID = outputDeviceUID

        let sessionID = UUID()
        playbackSessionID = sessionID
        playbackError = nil
        lastIcyStreamTitle = nil
        audibleStartedAt = nil

        // Play the .pls itself — AVFoundation's playlist handling is what
        // delivers ICY StreamTitle metadata (a direct ice URL plays silent of
        // metadata), and each restart re-fetches it for fresh servers. The
        // User-Agent matters: SomaFM drops anonymous clients, and the
        // identifying UA is part of polite unofficial use.
        let asset = AVURLAsset(
            url: stream.playlistURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": [
                "Icy-MetaData": "1",
                "User-Agent": SomaClient.userAgent,
            ]]
        )
        let item = AVPlayerItem(asset: asset)

        // Observe item status for errors — avoid capturing playerItem
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let error = observed.error?.localizedDescription
            Task { @MainActor [weak self] in
                switch status {
                case .failed:
                    self?.handleItemFailure(error)
                default:
                    break
                }
            }
        }
        itemNotificationTokens = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleItemFailure(nil) }
            },
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleItemFailure(nil) }
            },
        ]
        installMetadataOutput(on: item, channel: channel, sessionID: sessionID)

        log.info("startStream: \(channel.name, privacy: .public) via \(stream.playlistURL.lastPathComponent, privacy: .public)")
        player?.replaceCurrentItem(with: item)
        player?.play()
        phase = .buffering

        currentChannel = channel
        isPlaying = true
        currentTrackIdentityToken = nil

        currentTrack = NowPlaying(
            channelName: channel.name,
            artist: "",
            title: "Loading...",
            album: nil,
            artURL: channel.logoURL,
            duration: 0,
            startedAt: nil,
            elapsedOverride: nil
        )
        updateNowPlaying()
        loadChannelArtwork(channel: channel, sessionID: sessionID)
    }

    func pause() {
        cancelReconnect()
        autoResumeOnNetworkReturn = false
        player?.pause()
        isPlaying = false
        pausedAt = Date()
        phase = .paused
        enrichmentTask?.cancel()
        enrichmentTask = nil
        // A paused AVPlayer keeps downloading the live stream, but resume()
        // discards the buffer and restarts anyway once the pause passes 60s —
        // so after that point, drop the item and stop paying for dead bytes.
        pauseTeardownTimer?.invalidate()
        pauseTeardownTimer = Timer.scheduledTimer(withTimeInterval: 61, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tearDownPausedStream() }
        }
        pauseTeardownTimer?.tolerance = 5
        updateNowPlaying()
    }

    /// Releases the stream pipeline of a long-paused player. UI state
    /// (channel, track, artwork, paused phase) stays intact; resume() sees
    /// the missing item and takes its existing restart path.
    private func tearDownPausedStream() {
        pauseTeardownTimer = nil
        guard phase == .paused, !isPlaying else { return }
        statusObservation?.invalidate()
        statusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        metadataDelegate = nil
        player?.replaceCurrentItem(with: nil)
        log.info("paused >60s: released stream item")
    }

    func resume() {
        guard currentChannel != nil else { return }
        pauseTeardownTimer?.invalidate()
        pauseTeardownTimer = nil
        // A live buffer paused for long (or a dead item) is stale or badly
        // behind — restart the stream instead of resuming into silence.
        // (Past 60s the item may already be gone via tearDownPausedStream.)
        let pausedTooLong = pausedAt.map { Date().timeIntervalSince($0) > 60 } ?? false
        if let args = lastPlayArgs,
           pausedTooLong || player?.currentItem == nil || player?.currentItem?.status == .failed {
            play(channel: args.channel, stream: args.stream)
            return
        }
        pausedAt = nil
        player?.play()
        isPlaying = true
        phase = .buffering
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        cancelReconnect()
        reconnectAttempt = 0
        autoResumeOnNetworkReturn = false
        lastPlayArgs = nil
        lastItemError = nil
        pausedAt = nil
        pauseTeardownTimer?.invalidate()
        pauseTeardownTimer = nil
        hasPlayedThisSession = false
        phase = .idle
        enrichmentTask?.cancel()
        enrichmentTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        metadataDelegate = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isPlaying = false
        playbackError = nil
        currentChannel = nil
        currentTrack = nil
        currentArtImage = nil
        currentTrackIdentityToken = nil
        playbackSessionID = UUID()
        lastIcyStreamTitle = nil
        audibleStartedAt = nil
        clearNowPlaying()
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        isMuted = false // touching the slider unmutes, like the system slider
        player?.volume = newVolume
    }

    func toggleMute() {
        isMuted.toggle()
        player?.volume = isMuted ? 0 : volume
    }

    // MARK: - Output Routing

    /// CoreAudio device UID to play through; nil follows the system default.
    private(set) var outputDeviceUID: String?

    func setOutputDevice(uid: String?) {
        outputDeviceUID = uid
        player?.audioOutputDeviceUniqueID = uid
    }

    /// The underlying AVPlayer, exposed only for AVRoutePickerView (AirPlay).
    var routePickerPlayer: AVPlayer? { player }

    // MARK: - Stream Recovery

    private func handleTimeControlChange(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            hasPlayedThisSession = true
            reconnectAttempt = 0
            lastItemError = nil
            if isPlaying { phase = .playing }
        case .waitingToPlayAtSpecifiedRate:
            if isPlaying, reconnectTask == nil { phase = .buffering }
        case .paused:
            // A live stream dropping to .paused without user action is a stall.
            if isPlaying, reconnectTask == nil, phase == .playing {
                beginReconnect()
            }
        @unknown default:
            break
        }
    }

    private func handleItemFailure(_ errorDescription: String?) {
        guard isPlaying else { return }
        if let errorDescription { lastItemError = errorDescription }
        // An in-flight reconnect loop sees the failed item via waitUntilPlaying.
        guard reconnectTask == nil else { return }
        beginReconnect()
    }

    private func beginReconnect() {
        guard isPlaying, reconnectTask == nil, lastPlayArgs != nil else { return }
        // Startup failures (never audible this session) get a short ladder so
        // a dead stream surfaces quickly; mid-stream drops get the full one.
        let maxAttempts = hasPlayedThisSession ? Self.reconnectBackoff.count : 3
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(maxAttempts: maxAttempts)
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func runReconnectLoop(maxAttempts: Int) async {
        // A cancelled loop must not clear the slot — the canceller has already
        // reset it, possibly to a replacement task.
        defer { if !Task.isCancelled { reconnectTask = nil } }
        while reconnectAttempt < maxAttempts {
            let delay = Self.reconnectBackoff[min(reconnectAttempt, Self.reconnectBackoff.count - 1)]
            reconnectAttempt += 1
            phase = .reconnecting(attempt: reconnectAttempt)
            log.debug("RECONNECT: attempt \(self.reconnectAttempt, privacy: .public)/\(maxAttempts, privacy: .public) in \(delay, privacy: .public)s")
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, isPlaying, let args = lastPlayArgs else { return }

            isReconnectRestart = true
            play(channel: args.channel, stream: args.stream)
            isReconnectRestart = false
            phase = .reconnecting(attempt: reconnectAttempt)

            if await waitUntilPlaying(timeout: 15) {
                log.debug("RECONNECT: recovered")
                return
            }
            guard !Task.isCancelled, isPlaying else { return }
        }

        log.debug("RECONNECT: giving up after \(self.reconnectAttempt, privacy: .public) attempts")
        isPlaying = false
        phase = .failed
        autoResumeOnNetworkReturn = true
        playbackError = lastItemError ?? "Stream connection lost"
        updateNowPlaying()
    }

    private func waitUntilPlaying(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled || !isPlaying { return false }
            if player?.timeControlStatus == .playing { return true }
            if player?.currentItem?.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Called by PlaybackRecovery when the network path becomes satisfied.
    func networkPathRestored() {
        if isPlaying, isRecovering {
            reconnectAttempt = 0
            cancelReconnect()
            beginReconnect()
        } else if phase == .failed, autoResumeOnNetworkReturn, let args = lastPlayArgs {
            autoResumeOnNetworkReturn = false
            play(channel: args.channel, stream: args.stream)
        }
    }

    /// Called by PlaybackRecovery after system wake if playback was active.
    /// A slept live-stream item is never trustworthy — always restart (the
    /// .pls re-fetch picks up a fresh server assignment).
    func restartAfterWake() {
        guard isPlaying, let args = lastPlayArgs else { return }
        cancelReconnect()
        reconnectAttempt = 0
        play(channel: args.channel, stream: args.stream)
    }

    private func removeItemNotificationObservers() {
        for token in itemNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        itemNotificationTokens = []
    }

    // MARK: - Now Playing Info Center

    private func updateNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTrack?.title ?? currentChannel?.name ?? "SomaBar"
        info[MPMediaItemPropertyArtist] = currentTrack?.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentTrack?.album ?? currentChannel?.name ?? "SomaBar"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        if let image = currentArtImage {
            Task { await updateNowPlayingArtwork(image: image) }
        }
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Remote Commands (Media Keys)

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // ◀◀/▶▶ media keys step through favorite channels (wired by AppState)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNextTrack?()
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPreviousTrack?()
            return .success
        }
    }

    // MARK: - Channel Artwork

    /// SomaFM has no per-track art; the channel logo is the artwork for the
    /// whole session, loaded once per (re)start.
    private func loadChannelArtwork(channel: Channel, sessionID: UUID) {
        currentArtImage = nil
        guard let url = channel.logoURL else { return }
        Task { [weak self] in
            let image = await ArtCache.image(for: url)
            guard let self, self.playbackSessionID == sessionID, let image else { return }
            self.currentArtImage = image
            await self.updateNowPlayingArtwork(image: image)
        }
    }

    // MARK: - ICY Metadata (the sole track-change signal)

    private func installMetadataOutput(on item: AVPlayerItem, channel: Channel, sessionID: UUID) {
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        let delegate = StreamMetadataDelegate(
            owner: self,
            channel: channel,
            sessionID: sessionID
        )

        output.setDelegate(delegate, queue: DispatchQueue(label: "com.somabar.metadata"))
        // ICY titles arrive as timed metadata; 0.5s of delivery latency is
        // imperceptible and halves the delegate wakeups of the old 0.15s.
        output.advanceIntervalForDelegateInvocation = 0.5
        item.add(output)

        metadataOutput = output
        metadataDelegate = delegate
    }

    fileprivate func handleTimedMetadata(
        _ groups: [AVTimedMetadataGroup],
        channel: Channel,
        sessionID: UUID
    ) async {
        guard sessionID == playbackSessionID else { return }

        for group in groups {
            for item in group.items {
                guard let streamTitle = await extractIcyStreamTitle(from: item) else { continue }
                handleIcyStreamTitle(streamTitle, channel: channel, sessionID: sessionID)
                return
            }
        }
    }

    private func handleIcyStreamTitle(_ streamTitle: String, channel: Channel, sessionID: UUID) {
        guard sessionID == playbackSessionID else { return }

        let normalizedTitle = streamTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }
        guard normalizedTitle != lastIcyStreamTitle else { return }

        let isInitialSeed = lastIcyStreamTitle == nil
        lastIcyStreamTitle = normalizedTitle

        let (artist, title) = splitArtistAndTitle(from: normalizedTitle)
        let logicalKey = TrackMatching.songKey(artist: artist, title: title) ?? normalizedTitle.lowercased()

        // The first ICY packet reports a song already in progress — its start
        // time is unknown, so no elapsed ticks until the first real change.
        if isInitialSeed {
            audibleStartedAt = nil
            log.debug("ICY: initial stream title seed '\(normalizedTitle, privacy: .public)'")
        } else {
            audibleStartedAt = Date()
            log.debug("ICY: stream title update '\(normalizedTitle, privacy: .public)'")
        }

        currentTrack = NowPlaying(
            channelName: channel.name,
            artist: artist,
            title: title,
            album: nil,
            artURL: channel.logoURL,
            duration: 0,
            startedAt: audibleStartedAt,
            elapsedOverride: nil
        )
        currentTrackIdentityToken = "icy:\(logicalKey)"
        updateNowPlaying()
        scheduleEnrichment(channel: channel, artist: artist, title: title, sessionID: sessionID)
    }

    /// Merges the album name from songs/{id}.json into the current track.
    /// One fetch ~5s after the ICY change (the feed lags the stream), one
    /// retry at +20s — no continuous polling; ICY drives everything else.
    private func scheduleEnrichment(channel: Channel, artist: String, title: String, sessionID: UUID) {
        enrichmentTask?.cancel()
        enrichmentTask = Task { [weak self] in
            for delay in [5.0, 20.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.playbackSessionID == sessionID else { return }
                guard let songs = try? await SomaClient.fetchRecentSongs(channelId: channel.id) else { continue }
                guard !Task.isCancelled, self.playbackSessionID == sessionID else { return }

                let match = songs.first { song in
                    TrackMatching.sameSong(
                        artistA: song.artist ?? "", titleA: song.title ?? "",
                        artistB: artist, titleB: title
                    )
                }
                guard let match else { continue }
                guard let track = self.currentTrack, track.artist == artist, track.title == title else { return }

                let album = (match.album?.isEmpty == false) ? match.album : nil
                self.currentTrack = NowPlaying(
                    channelName: track.channelName,
                    artist: track.artist,
                    title: track.title,
                    album: album,
                    artURL: track.artURL,
                    duration: track.duration,
                    startedAt: track.startedAt,
                    elapsedOverride: track.elapsedOverride
                )
                self.updateNowPlaying()
                return
            }
        }
    }

    private func extractIcyStreamTitle(from item: AVMetadataItem) async -> String? {
        let identifierRaw = item.identifier?.rawValue.lowercased() ?? ""
        let keySpaceRaw = item.keySpace?.rawValue.lowercased() ?? ""
        let keyRaw = String(describing: item.key).lowercased()
        let looksLikeStreamTitle =
            identifierRaw.contains("streamtitle")
            || (keySpaceRaw == "icy" && keyRaw.contains("streamtitle"))
            || keyRaw == "optional(streamtitle)"

        guard looksLikeStreamTitle else { return nil }

        if let text = try? await item.load(.stringValue),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let value = try? await item.load(.value) {
            if let text = value as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let text = value as? NSString,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text as String
            }
        }

        return nil
    }

    private func splitArtistAndTitle(from streamTitle: String) -> (String, String) {
        let separators = [" - ", " — ", " – "]

        for separator in separators {
            if let range = streamTitle.range(of: separator) {
                let artist = String(streamTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = String(streamTitle[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !artist.isEmpty && !title.isEmpty {
                    return (artist, title)
                }
            }
        }

        return ("", streamTitle)
    }

    private func updateNowPlayingArtwork(image: NSImage?) async {
        guard let image else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

private final class StreamMetadataDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    weak var owner: AudioPlayer?
    let channel: Channel
    let sessionID: UUID

    init(owner: AudioPlayer, channel: Channel, sessionID: UUID) {
        self.owner = owner
        self.channel = channel
        self.sessionID = sessionID
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        Task { [weak owner] in
            await owner?.handleTimedMetadata(groups, channel: channel, sessionID: sessionID)
        }
    }
}
