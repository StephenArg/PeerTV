import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var session: SessionStore
    private let shuffleEnabled: Bool

    init() {
        self.shuffleEnabled = DebugFlags.shuffleTabEnabled
    }

    var body: some View {
        TabView {
            HomeTab()
                .tabItem { Label("Home", systemImage: "flame") }

            if shuffleEnabled {
                ShuffleTab()
                    .tabItem { Label("Shuffle", systemImage: "shuffle") }
            }
            
            SubscriptionsTab()
                .tabItem { Label("Subscriptions", systemImage: "bell") }
            
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
            
            PlaylistsTab()
                .tabItem { Label("Playlists", systemImage: "list.and.film") }

            ChannelsTab()
                .tabItem { Label("Channels", systemImage: "person.2") }
            
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
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
