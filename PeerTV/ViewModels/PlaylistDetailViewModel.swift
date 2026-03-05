import Foundation

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published var playlist: VideoPlaylist?
    @Published var elements: [PlaylistElement] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    let playlistId: Int

    init(playlistId: Int) {
        self.playlistId = playlistId
    }

    func configure(apiClient: PeerTubeAPIClient) {
        self.apiClient = apiClient
    }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    func loadInitial() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            playlist = try await apiClient.request(.playlistDetail(id: playlistId))
            let resp: PaginatedResponse<PlaylistElement> = try await apiClient.request(
                .playlistVideos(id: playlistId, start: 0, count: pageSize)
            )
            elements = resp.items
            currentStart = resp.items.count
            total = resp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let apiClient, !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let resp: PaginatedResponse<PlaylistElement> = try await apiClient.request(
                .playlistVideos(id: playlistId, start: currentStart, count: pageSize)
            )
            elements.append(contentsOf: resp.items)
            currentStart += resp.items.count
            total = resp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
