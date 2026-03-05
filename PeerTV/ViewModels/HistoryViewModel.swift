import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var videos: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?

    func configure(apiClient: PeerTubeAPIClient) {
        self.apiClient = apiClient
    }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    func loadInitial() async {
        currentStart = 0
        videos = []
        await loadMore()
    }

    func loadMore() async {
        guard let apiClient, !isLoading, canLoadMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response: PaginatedResponse<Video> = try await apiClient.request(
                .myHistory(start: currentStart, count: pageSize)
            )
            total = response.total
            let existingIds = Set(videos.map(\.stableId))
            let unique = response.items.filter { !existingIds.contains($0.stableId) }
            videos.append(contentsOf: unique)
            currentStart += response.items.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
