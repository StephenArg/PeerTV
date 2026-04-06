import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var playlistEditCoordinator = PlaylistEditCoordinator()
    private let shuffleEnabled: Bool

    @State private var selectedTab: MainTabSelection = .home
    /// Bumped whenever the Playlists tab is selected so the list refetches (TabView often skips `onAppear` on return).
    @State private var playlistsTabRefreshToken = 0

    init() {
        self.shuffleEnabled = DebugFlags.shuffleTabEnabled
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(MainTabSelection.home)

            if shuffleEnabled {
                ShuffleTab()
                    .tabItem { Label("Shuffle", systemImage: "shuffle") }
                    .tag(MainTabSelection.shuffle)
            }

            PlaylistsTab()
                .tabItem { Label("Playlists", systemImage: "list.and.film") }
                .tag(MainTabSelection.playlists)

            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(MainTabSelection.history)

            SubscriptionsTab()
                .tabItem { Label("Subscriptions", systemImage: "bell") }
                .tag(MainTabSelection.subscriptions)

            ChannelsTab()
                .tabItem { Label("Channels", systemImage: "person.2") }
                .tag(MainTabSelection.channels)

            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(MainTabSelection.settings)
        }
        .environmentObject(playlistEditCoordinator)
        .environment(\.peerTVPlaylistsTabRefreshToken, playlistsTabRefreshToken)
        .overlay {
            TabBarControllerFocusLock(locked: playlistEditCoordinator.isRepositioning)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .onChange(of: selectedTab) { _, newTab in
            if playlistEditCoordinator.isRepositioning && newTab != .playlists {
                selectedTab = .playlists
            }
            if newTab == .playlists {
                playlistsTabRefreshToken += 1
            }
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
                    PlaylistDetailView(playlistId: id)
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
            SubscriptionsView()
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
