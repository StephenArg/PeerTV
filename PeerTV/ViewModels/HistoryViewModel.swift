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

    /// First load only — avoids wiping scroll position when the view reappears (e.g. after closing the player).
    func loadInitialIfEmpty() async {
        guard videos.isEmpty else { return }
        await loadInitial()
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

    /// Removes one video from the server-side history. The row disappears immediately and comes
    /// back if the request fails. Returns `false` on failure.
    @discardableResult
    func remove(_ video: Video) async -> Bool {
        guard let apiClient, let numericId = video.id else { return false }
        let index = videos.firstIndex(where: { $0.stableId == video.stableId })
        if let index { videos.remove(at: index) }
        do {
            _ = try await apiClient.rawRequest(.removeHistoryVideo(videoId: numericId))
            // A loaded row shifted the server list by one; keep the next page from skipping a row.
            if index != nil { currentStart = max(0, currentStart - 1) }
            total = total.map { max(0, $0 - 1) }
            return true
        } catch {
            if let index { videos.insert(video, at: min(index, videos.count)) }
            return false
        }
    }

    /// Clears the whole server-side history. Returns `false` on failure (the list is left as is).
    @discardableResult
    func clearAll() async -> Bool {
        guard let apiClient else { return false }
        do {
            _ = try await apiClient.rawRequest(.clearHistory)
            videos = []
            currentStart = 0
            total = nil
            return true
        } catch {
            return false
        }
    }
}
