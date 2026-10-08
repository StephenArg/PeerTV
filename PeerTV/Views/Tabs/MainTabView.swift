import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playlistEditCoordinator = PlaylistEditCoordinator()
    /// Live, so toggling the Shuffle tab in Settings adds or removes it without relaunching.
    @AppStorage(DebugFlags.shuffleTabKey) private var shuffleEnabled = false
    @AppStorage(TabBarStyle.storageKey) private var tabBarStyle: TabBarStyle = .topBar

    @State private var selectedTab: MainTabSelection = .home
    /// Bumped whenever the Playlists tab is selected so the list refetches (TabView often skips `onAppear` on return).
    @State private var playlistsTabRefreshToken = 0
    /// Bumped when History, Subscriptions or Channels should refresh in place: the tab was selected, or the
    /// app came back to the foreground on it. tvOS suspends the app instead of quitting it, so without
    /// this those lists would only load once.
    @State private var historyTabRefreshToken = 0
    @State private var subscriptionsTabRefreshToken = 0
    @State private var channelsTabRefreshToken = 0
    @State private var inPlaceRefreshTask: Task<Void, Never>?
    @State private var wasBackgrounded = false
    /// Last time the user left the Shuffle tab; used to refetch only after a long absence (see `ShuffleView`).
    @State private var shuffleTabLeftAt: Date?
    @State private var shuffleStaleRefreshToken = 0

    private static let shuffleTabStaleAwaySeconds: TimeInterval = 60
    /// How long a tab must stay selected before it refreshes. Moving along the tab bar selects every
    /// tab on the way, and those shouldn't each fire a request.
    private static let inPlaceRefreshSettleNanoseconds: UInt64 = 400_000_000

    private var isAnonymous: Bool { session.isAnonymous }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(MainTabSelection.home)

            if !isAnonymous {
                PlaylistsTab()
                    .tabItem { Label("Playlists", systemImage: "list.and.film") }
                    .tag(MainTabSelection.playlists)

                if shuffleEnabled {
                    ShuffleTab()
                        .tabItem { Label("Shuffle", systemImage: "shuffle") }
                        .tag(MainTabSelection.shuffle)
                }
            }

            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(MainTabSelection.history)

            if !isAnonymous {
                SubscriptionsTab()
                    .tabItem { Label("Subscriptions", systemImage: "bell") }
                    .tag(MainTabSelection.subscriptions)
            }

            // Channels are public, so anonymous browsing with a server gets them too.
            if session.canBrowseInstance {
                ChannelsTab()
                    .tabItem { Label("Channels", systemImage: "person.2") }
                    .tag(MainTabSelection.channels)
            }

            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(MainTabSelection.settings)
        }
        .modifier(TabBarStyleModifier(style: tabBarStyle))
        .onChange(of: session.isAnonymous) { _, anonymous in
            guard anonymous else { return }
            let stillAvailable: Set<MainTabSelection> = session.canBrowseInstance
                ? [.home, .history, .channels, .settings]
                : [.home, .history, .settings]
            if !stillAvailable.contains(selectedTab) {
                selectedTab = .home
            }
        }
        .onChange(of: shuffleEnabled) { _, enabled in
            if !enabled, selectedTab == .shuffle {
                selectedTab = .home
            }
        }
        .environmentObject(playlistEditCoordinator)
        .environment(\.peerTVPlaylistsTabRefreshToken, playlistsTabRefreshToken)
        .environment(\.peerTVHistoryTabRefreshToken, historyTabRefreshToken)
        .environment(\.peerTVSubscriptionsTabRefreshToken, subscriptionsTabRefreshToken)
        .environment(\.peerTVChannelsTabRefreshToken, channelsTabRefreshToken)
        .environment(\.peerTVShuffleTabStaleRefreshToken, shuffleStaleRefreshToken)
        .overlay {
            TabBarControllerFocusLock(locked: playlistEditCoordinator.isRepositioning)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            if playlistEditCoordinator.isRepositioning && newTab != .playlists {
                selectedTab = .playlists
            }
            if newTab == .playlists {
                playlistsTabRefreshToken += 1
            }
            if shuffleEnabled {
                if oldTab == .shuffle {
                    shuffleTabLeftAt = Date()
                }
                if newTab == .shuffle,
                   let leftAt = shuffleTabLeftAt,
                   Date().timeIntervalSince(leftAt) > Self.shuffleTabStaleAwaySeconds {
                    shuffleStaleRefreshToken += 1
                }
            }
            scheduleInPlaceRefresh(for: newTab)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasBackgrounded = true
            case .active where wasBackgrounded:
                // tvOS resumes a suspended process instead of relaunching, so nothing else reloads these lists.
                wasBackgrounded = false
                bumpInPlaceRefreshToken(for: selectedTab)
            default:
                break
            }
        }
    }

    private func scheduleInPlaceRefresh(for tab: MainTabSelection) {
        inPlaceRefreshTask?.cancel()
        inPlaceRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.inPlaceRefreshSettleNanoseconds)
            guard !Task.isCancelled, selectedTab == tab else { return }
            bumpInPlaceRefreshToken(for: tab)
        }
    }

    private func bumpInPlaceRefreshToken(for tab: MainTabSelection) {
        switch tab {
        case .history:
            historyTabRefreshToken += 1
        case .subscriptions:
            subscriptionsTabRefreshToken += 1
        case .channels:
            channelsTabRefreshToken += 1
        case .home, .shuffle, .playlists, .settings:
            break
        }
    }
}

/// How the main tabs are presented (Settings → Navigation). Persisted via `@AppStorage`.
enum TabBarStyle: String, CaseIterable, Identifiable {
    case sidebar
    case topBar

    static let storageKey = "PeerTV.tabBarStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sidebar: "Sidebar"
        case .topBar: "Top bar"
        }
    }
}

/// The sidebar needs tvOS 18; tvOS 17 always shows the top tab bar.
private struct TabBarStyleModifier: ViewModifier {
    let style: TabBarStyle

    func body(content: Content) -> some View {
        if style == .sidebar {
            if #available(tvOS 18.0, *) {
                content.tabViewStyle(.sidebarAdaptable)
            } else {
                content
            }
        } else {
            content
        }
    }
}

private enum MainTabSelection: Hashable {
    case home
    case shuffle
    case subscriptions
    case history
    case playlists
    case channels
    case settings
}

// MARK: - Shared navigation destinations

/// Attaches all shared navigationDestination handlers to a NavigationStack.
/// Centralising these avoids duplicates and ensures the tvOS focus engine
/// can always resolve the back-navigation chain.
private struct SharedNavigationDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Video.self) { video in
                VideoDetailView(videoId: video.stableId)
            }
            .navigationDestination(for: VideoChannel.self) { channel in
                ChannelDetailView(handle: channel.handle)
            }
            .navigationDestination(for: VideoPlaylist.self) { playlist in
                if let id = playlist.id {
                    PlaylistDetailView(playlistId: id, initialPlaylistPathId: playlist.peertubePlaylistPathId)
                }
            }
    }
}

private extension View {
    func withSharedDestinations() -> some View {
        modifier(SharedNavigationDestinations())
    }
}

// MARK: - Tab wrappers with explicit NavigationPath

private struct HomeTab: View {
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            VideoGridView()
                .withSharedDestinations()
        }
    }
}

private struct ChannelsTab: View {
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            ChannelsListView()
                .withSharedDestinations()
        }
    }
}

private struct SubscriptionsTab: View {
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            SubscriptionsView(isAtNavigationRoot: path.isEmpty)
                .withSharedDestinations()
        }
    }
}

private struct PlaylistsTab: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            PlaylistListView()
                .withSharedDestinations()
        }
    }
}

private struct ShuffleTab: View {
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            ShuffleView()
                .withSharedDestinations()
        }
    }
}

private struct SettingsTab: View {
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            SettingsView()
        }
    }
}

private struct HistoryTab: View {
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            HistoryView()
                .withSharedDestinations()
        }
    }
}
