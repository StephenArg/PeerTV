import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var videos: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sort: String = "-trending"

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    private var isAuthenticated = false

    func configure(apiClient: PeerTubeAPIClient, isAuthenticated: Bool) {
        self.apiClient = apiClient
        self.isAuthenticated = isAuthenticated
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
                .videos(sort: sort, start: currentStart, count: pageSize, includeAllPrivacy: isAuthenticated)
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

    func changeSort(_ newSort: String) async {
        sort = newSort
        await loadInitial()
    }
}
