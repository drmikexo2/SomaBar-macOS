import SwiftUI

struct PlayingRevealRequest: Equatable {
    let channelID: String

    var itemID: String { channelID }

    static func resolve(channelID: String?) -> PlayingRevealRequest? {
        guard let channelID else { return nil }
        return PlayingRevealRequest(channelID: channelID)
    }
}

struct StationListView: View {
    @Environment(AppState.self) private var appState
    @State private var allStationsExpanded = Prefs.bool(.allStationsExpanded, default: true)
    @State private var recentExpanded = Prefs.bool(.recentStationsExpanded, default: true)
    @State private var highlightedIndex: Int?
    @State private var pendingPlayingReveal: PlayingRevealRequest?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search channels...", text: Bindable(appState).searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) {
                        moveHighlight(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveHighlight(by: -1)
                        return .handled
                    }
                    .onSubmit {
                        let channels = appState.filteredChannels
                        let index = highlightedIndex ?? (appState.searchText.isEmpty ? nil : 0)
                        if let index, channels.indices.contains(index) {
                            appState.playChannel(channels[index])
                        }
                    }
                    .onExitCommand {
                        appState.searchText = ""
                        highlightedIndex = nil
                        searchFocused = false
                    }
                if !appState.searchText.isEmpty {
                    Button(action: { appState.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))

            if appState.isLoading && !appState.channelsLoaded {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading channels...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // pinnedViews makes the section headers sticky: each
                        // pins at the top until the next header pushes it off
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            let searching = !appState.searchText.isEmpty
                            let showFavorites = !searching && !appState.favoriteChannels.isEmpty
                            let showRecents = !searching && !appState.recentStations.isEmpty
                            let showSections = showFavorites || showRecents

                            // Favorites
                            if showFavorites {
                                Section {
                                    ForEach(appState.favoriteChannels) { item in
                                        ChannelRow(item: item)
                                            .id("fav-\(item.id)")
                                    }
                                    Divider()
                                        .padding(.top, 8)
                                } header: {
                                    SectionHeader(title: "My Favorites")
                                }
                            }

                            // Recently played
                            if showRecents {
                                Section {
                                    if recentExpanded {
                                        ForEach(appState.recentStations) { entry in
                                            RecentRow(entry: entry)
                                        }
                                    }
                                    Divider()
                                        .padding(.top, 8)
                                } header: {
                                    SectionHeader(
                                        title: "My Recently Played Channels",
                                        isExpanded: $recentExpanded
                                    )
                                }
                            }

                            if showSections {
                                Section {
                                    if allStationsExpanded {
                                        allChannelRows
                                    }
                                } header: {
                                    SectionHeader(
                                        title: allChannelsTitle,
                                        isExpanded: $allStationsExpanded
                                    )
                                }
                            } else {
                                allChannelRows
                            }
                        }
                    }
                    .frame(height: appState.artworkExpanded ? 180 : 280)
                    .onAppear {
                        searchFocused = true
                        if pendingPlayingReveal != nil {
                            fulfillPendingPlayingReveal(proxy: proxy)
                        } else {
                            scrollToPlaying(proxy: proxy)
                        }
                    }
                    .background(
                        // Cmd+L jumps to the playing station, as in iTunes
                        Button("") { requestPlayingReveal(proxy: proxy) }
                            .keyboardShortcut("l", modifiers: .command)
                            .opacity(0)
                    )
                    .onChange(of: pendingPlayingRevealIsAvailable) { _, available in
                        if available {
                            fulfillPendingPlayingReveal(proxy: proxy)
                        }
                    }
                    .onChange(of: highlightedIndex) { _, index in
                        if let index, appState.filteredChannels.indices.contains(index) {
                            proxy.scrollTo("all-\(appState.filteredChannels[index].id)", anchor: .center)
                        }
                    }
                }
            }
        }
        .onChange(of: allStationsExpanded) { _, expanded in
            Prefs.set(expanded, for: .allStationsExpanded)
        }
        .onChange(of: recentExpanded) { _, expanded in
            Prefs.set(expanded, for: .recentStationsExpanded)
        }
        .onChange(of: appState.searchText) { _, _ in
            highlightedIndex = nil
        }
        .onChange(of: searchFocused) { _, focused in
            appState.searchFieldFocused = focused
        }
        .onChange(of: appState.isLoading) { _, loading in
            guard pendingPlayingReveal != nil else { return }
            if !loading, appState.channelsLoaded {
                // The catalog is loaded; either the row resolves now or the
                // playing station is gone.
                fulfillPendingPlayingReveal(proxy: nil)
            }
        }
    }

    private var allChannelsTitle: String {
        "All Channels (\(appState.filteredChannels.count))"
    }

    private var pendingPlayingRevealIsAvailable: Bool {
        guard let request = pendingPlayingReveal else { return false }
        return rowTarget(for: request) != nil
    }

    /// Keep the intent pending until the channel rows have loaded and
    /// rendered.
    private func requestPlayingReveal(proxy: ScrollViewProxy) {
        guard let request = PlayingRevealRequest.resolve(
            channelID: appState.audioPlayer.currentChannel?.id
        ) else {
            pendingPlayingReveal = nil
            return
        }

        pendingPlayingReveal = request

        if !appState.searchText.isEmpty,
           !appState.filteredChannels.contains(where: { $0.id == request.itemID }) {
            // A navigation command should reveal its destination even when
            // the current search happens to filter that station out.
            appState.searchText = ""
        }

        fulfillPendingPlayingReveal(proxy: proxy)
    }

    private func fulfillPendingPlayingReveal(proxy: ScrollViewProxy?) {
        guard let request = pendingPlayingReveal else { return }
        if let proxy, scroll(to: request, proxy: proxy, animated: true) {
            pendingPlayingReveal = nil
        } else if appState.channelsLoaded, rowTarget(for: request) == nil {
            // The catalog loaded but no longer contains the playing station.
            pendingPlayingReveal = nil
        }
    }

    /// Opening the panel centers the playing row when it's on screen.
    private func scrollToPlaying(proxy: ScrollViewProxy) {
        guard let request = PlayingRevealRequest.resolve(
            channelID: appState.audioPlayer.currentChannel?.id
        ) else { return }
        _ = scroll(to: request, proxy: proxy, animated: false)
    }

    /// A playing favorite is shown in its Favorites row at the top, not its
    /// duplicate in All Channels. Expanding or replacing list contents needs
    /// one main-loop turn before ScrollViewReader can resolve the row ID.
    @discardableResult
    private func scroll(
        to request: PlayingRevealRequest,
        proxy: ScrollViewProxy,
        animated: Bool
    ) -> Bool {
        guard let target = rowTarget(for: request) else { return false }
        if target.hasPrefix("all-"), !allStationsExpanded {
            allStationsExpanded = true
        }

        let scroll: (String) -> Void = { target in
            if animated {
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            } else {
                proxy.scrollTo(target, anchor: .center)
            }
        }
        DispatchQueue.main.async { scroll(target) }
        return true
    }

    private func rowTarget(for request: PlayingRevealRequest) -> String? {
        let itemId = request.itemID
        if appState.searchText.isEmpty,
           appState.favoriteChannels.contains(where: { $0.id == itemId }) {
            return "fav-\(itemId)"
        }
        if appState.filteredChannels.contains(where: { $0.id == itemId }) {
            return "all-\(itemId)"
        }
        return nil
    }

    private func moveHighlight(by delta: Int) {
        let count = appState.filteredChannels.count
        guard count > 0 else { return }
        // Arrow keys navigate the All Stations list, so make sure it's visible
        if !allStationsExpanded { allStationsExpanded = true }
        let current = highlightedIndex ?? -1
        highlightedIndex = min(max(current + delta, 0), count - 1)
    }

    private var allChannelRows: some View {
        ForEach(Array(appState.filteredChannels.enumerated()), id: \.element.id) { index, item in
            ChannelRow(item: item, isHighlighted: index == highlightedIndex)
                .id("all-\(item.id)")
        }
    }
}

// MARK: - Channel Row

struct ChannelRow: View {
    @Environment(AppState.self) private var appState
    let item: Channel
    var isHighlighted: Bool = false
    @State private var isHovered = false

    private var isPlaying: Bool {
        appState.audioPlayer.currentChannel?.id == item.id
    }

    private var isFavorite: Bool {
        appState.favoriteIds.contains(item.id)
    }

    var body: some View {
        Button(action: { appState.playChannel(item) }) {
            HStack(spacing: 4) {
                Text(item.name)
                    .font(.system(size: 12))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .playingHighlight(isPlaying)
                Spacer()

                // Fixed-width slots keep the star column aligned on every row
                SpeakerIndicator(isCurrent: isPlaying, isAudible: appState.audioPlayer.isAudiblyPlaying)

                Group {
                    if isFavorite || isHovered {
                        Button(action: { appState.toggleFavorite(item) }) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow.opacity(0.65)) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 14)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.description ?? item.name)
        .background(
            isPlaying
                ? Color.accentColor.opacity(0.1)
                : (isHighlighted || isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Recent Row

/// Row in the Recently Played section — like ChannelRow but for the MRU list.
struct RecentRow: View {
    @Environment(AppState.self) private var appState
    let entry: RecentStation
    @State private var isHovered = false

    private var isPlaying: Bool {
        appState.audioPlayer.currentChannel?.id == entry.channelId
    }

    private var isFavorite: Bool {
        appState.favoriteIds.contains(entry.channelId)
    }

    var body: some View {
        Button(action: { appState.playRecentStation(entry) }) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 12))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .playingHighlight(isPlaying)
                Spacer()

                SpeakerIndicator(isCurrent: isPlaying, isAudible: appState.audioPlayer.isAudiblyPlaying)

                Group {
                    if isFavorite || isHovered {
                        Button(action: { appState.toggleFavorite(channelId: entry.channelId, name: entry.name) }) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow.opacity(0.65)) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 14)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isPlaying
                ? Color.accentColor.opacity(0.1)
                : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var isExpanded: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                // Never let a sticky header wrap to two lines
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if let isExpanded {
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.wrappedValue.toggle()
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                }
                .buttonStyle(.plain)
                .help(isExpanded.wrappedValue ? "Collapse" : "Expand")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 11)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Behind-window sampling makes this indistinguishable from the panel
        // base at rest, yet it occludes rows sliding under a pinned header —
        // so no pin detection is needed.
        .background(PanelMaterial())
    }
}
