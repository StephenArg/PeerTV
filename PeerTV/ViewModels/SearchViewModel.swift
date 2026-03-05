import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var results: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    private(set) var activeQuery = ""

    func configure(apiClient: PeerTubeAPIClient) {
        self.apiClient = apiClient
    }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let apiClient else { return }

        activeQuery = trimmed
        currentStart = 0
        results = []
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let response: PaginatedResponse<Video> = try await apiClient.request(
                .searchVideos(search: trimmed, start: 0, count: pageSize)
            )
            guard activeQuery == trimmed else { return }
            total = response.total
            results = response.items
            currentStart = response.items.count
        } catch {
            guard activeQuery == trimmed else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let apiClient, !isLoading, canLoadMore,
              !activeQuery.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response: PaginatedResponse<Video> = try await apiClient.request(
                .searchVideos(search: activeQuery, start: currentStart, count: pageSize)
            )
            total = response.total
            let existingIds = Set(results.map(\.stableId))
            let unique = response.items.filter { !existingIds.contains($0.stableId) }
            results.append(contentsOf: unique)
            currentStart += response.items.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        activeQuery = ""
        results = []
        total = nil
        currentStart = 0
        errorMessage = nil
    }
}
