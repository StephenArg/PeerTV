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
