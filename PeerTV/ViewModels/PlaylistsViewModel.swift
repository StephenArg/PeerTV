import Foundation

@MainActor
final class PlaylistsViewModel: ObservableObject {
    @Published var playlists: [VideoPlaylist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    private var accountName: String?

    func configure(apiClient: PeerTubeAPIClient, accountName: String? = nil) {
        self.apiClient = apiClient
        self.accountName = accountName
    }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    func loadInitial() async {
        // Clear loading/total so a new fetch always runs (avoids guard failures after cancellation or pagination).
        isLoading = false
        total = nil
        currentStart = 0
        playlists = []
        await loadMore()
    }

    func loadMore() async {
        guard let apiClient, !isLoading, canLoadMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let endpoint: Endpoint
            if let name = accountName, !name.isEmpty {
                endpoint = .accountPlaylists(name: name, start: currentStart, count: pageSize)
            } else {
                endpoint = .videoPlaylists(start: currentStart, count: pageSize)
            }
            let response: PaginatedResponse<VideoPlaylist> = try await apiClient.request(endpoint)
            total = response.total
            playlists.append(contentsOf: response.items)
            currentStart += response.items.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension Notification.Name {
    /// Posted when playlist membership may have changed (e.g. add-to-playlist) or when the Playlists tab is focused.
    static let peerTVPlaylistsNeedRefresh = Notification.Name("PeerTV.playlistsNeedRefresh")

    /// Posted when playlist autoplay advances (or starts) so the grid can scroll and move focus to the active tile.
    static let peerTVPlaylistNowPlayingVideoId = Notification.Name("PeerTV.playlistNowPlayingVideoId")

    /// Posted when the player is dismissed so the playlist can restore focus to the last-played tile.
    static let peerTVPlayerDismissed = Notification.Name("PeerTV.playerDismissed")
}
