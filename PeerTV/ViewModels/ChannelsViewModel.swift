import Foundation

@MainActor
final class ChannelsViewModel: ObservableObject {
    @Published var channels: [VideoChannel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    /// Set while `refreshInPlace` runs. Kept off `isLoading` so the spinner doesn't flash.
    private var isRefreshing = false
    /// A page requested while a refresh was replacing the list; loaded once the refresh lands.
    private var loadMoreDeferred = false

    func configure(apiClient: PeerTubeAPIClient) {
        self.apiClient = apiClient
    }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    func loadInitial() async {
        currentStart = 0
        channels = []
        await loadMore()
    }

    /// First load only — avoids wiping scroll position when the view reappears (e.g. after coming back from a channel).
    func loadInitialIfEmpty() async {
        guard channels.isEmpty else { return }
        await loadInitial()
    }

    /// Refetches the rows already loaded without clearing the list first, so scroll position and
    /// focus survive. On failure the rows on screen are kept.
    func refreshInPlace() async {
        guard let apiClient, !isLoading, !isRefreshing else { return }
        isRefreshing = true
        // Refetch as many rows as are already loaded so a deep scroll position still exists.
        let count = min(max(pageSize, channels.count), 100)
        do {
            let response: PaginatedResponse<VideoChannel> = try await apiClient.request(
                .videoChannels(start: 0, count: count)
            )
            let fresh = response.items
            let freshIds = Set(fresh.compactMap(\.id))
            // A request returns at most 100 rows; rows loaded beyond that stay, after the fresh ones.
            channels = channels.count > count
                ? fresh + channels.filter { channel in channel.id.map { !freshIds.contains($0) } ?? false }
                : fresh
            total = response.total
            currentStart = max(response.items.count, channels.count)
            errorMessage = nil
        } catch {
            // Keep the rows on screen; the next refresh tries again.
        }
        isRefreshing = false
        if loadMoreDeferred {
            loadMoreDeferred = false
            await loadMore()
        }
    }

    func loadMore() async {
        if isRefreshing {
            loadMoreDeferred = true
            return
        }
        guard let apiClient, !isLoading, canLoadMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response: PaginatedResponse<VideoChannel> = try await apiClient.request(
                .videoChannels(start: currentStart, count: pageSize)
            )
            total = response.total
            channels.append(contentsOf: response.items)
            currentStart += response.items.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
