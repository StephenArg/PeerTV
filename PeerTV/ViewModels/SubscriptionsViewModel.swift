import Foundation

@MainActor
final class SubscriptionsViewModel: ObservableObject {
    @Published var subscriptions: [Subscription] = []
    @Published var feedVideos: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    /// The API returns at most 100 subscriptions per request.
    private let subscriptionsPageSize = 100
    private var feedStart = 0
    private var feedTotal: Int?
    private var apiClient: PeerTubeAPIClient?
    /// Set while `refreshInPlace` runs. Kept off `isLoading` so the spinner and the empty state don't flash.
    private var isRefreshing = false
    /// A feed page requested while a refresh was replacing the list; loaded once the refresh lands.
    private var loadMoreDeferred = false

    func configure(apiClient: PeerTubeAPIClient) {
        self.apiClient = apiClient
    }

    var canLoadMoreFeed: Bool {
        guard let feedTotal else { return true }
        return feedStart < feedTotal
    }

    func loadInitial() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let subs = fetchAllSubscriptions(using: apiClient)
            async let feed: PaginatedResponse<Video> = apiClient.request(
                .mySubscriptionVideos(start: 0, count: pageSize, sort: "-publishedAt")
            )
            let (allSubs, feedResp) = try await (subs, feed)
            subscriptions = allSubs
            feedVideos = feedResp.items
            feedStart = feedResp.items.count
            feedTotal = feedResp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// First load only — avoids wiping scroll position when the view reappears (e.g. after closing the player).
    func loadInitialIfEmpty() async {
        guard feedVideos.isEmpty else { return }
        await loadInitial()
    }

    /// Refetches the channel row and the feed rows already loaded without clearing them first, so
    /// scroll position and focus survive. On failure what's on screen is kept.
    func refreshInPlace() async {
        guard let apiClient, !isLoading, !isRefreshing else { return }
        isRefreshing = true
        // Refetch as many rows as are already loaded so a deep scroll position still exists.
        let count = min(max(pageSize, feedVideos.count), 100)
        do {
            async let subs = fetchAllSubscriptions(using: apiClient)
            async let feed: PaginatedResponse<Video> = apiClient.request(
                .mySubscriptionVideos(start: 0, count: count, sort: "-publishedAt")
            )
            let (allSubs, feedResp) = try await (subs, feed)
            subscriptions = allSubs
            var seen = Set<String>()
            let fresh = feedResp.items.filter { seen.insert($0.stableId).inserted }
            // A request returns at most 100 rows; rows loaded beyond that stay, after the fresh ones.
            feedVideos = feedVideos.count > count
                ? fresh + feedVideos.filter { !seen.contains($0.stableId) }
                : fresh
            feedStart = max(feedResp.items.count, feedVideos.count)
            feedTotal = feedResp.total
            errorMessage = nil
        } catch {
            // Keep the rows on screen; the next refresh tries again.
        }
        isRefreshing = false
        if loadMoreDeferred {
            loadMoreDeferred = false
            await loadMoreFeed()
        }
    }

    func loadMoreFeed() async {
        if isRefreshing {
            loadMoreDeferred = true
            return
        }
        guard let apiClient, !isLoading, canLoadMoreFeed else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let resp: PaginatedResponse<Video> = try await apiClient.request(
                .mySubscriptionVideos(start: feedStart, count: pageSize, sort: "-publishedAt")
            )
            let existingIds = Set(feedVideos.map(\.stableId))
            let unique = resp.items.filter { !existingIds.contains($0.stableId) }
            feedVideos.append(contentsOf: unique)
            feedStart += resp.items.count
            feedTotal = resp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Every subscribed channel, for the row above the feed. A request returns at most
    /// `subscriptionsPageSize`, so this pages until `total`.
    private func fetchAllSubscriptions(using apiClient: PeerTubeAPIClient) async throws -> [Subscription] {
        var all: [Subscription] = []
        while true {
            let page: PaginatedResponse<Subscription>
            do {
                page = try await apiClient.request(
                    .mySubscriptions(start: all.count, count: subscriptionsPageSize)
                )
            } catch {
                // A later page failing shouldn't cost the ones already loaded.
                if all.isEmpty { throw error }
                break
            }
            all.append(contentsOf: page.items)
            guard !page.items.isEmpty, let total = page.total, all.count < total else { break }
        }
        // Paging while the list changes on the server can repeat a channel; the row needs unique ids.
        var seenIds = Set<Int>()
        return all.filter { channel in
            guard let id = channel.id else { return true }
            return seenIds.insert(id).inserted
        }
    }
}
