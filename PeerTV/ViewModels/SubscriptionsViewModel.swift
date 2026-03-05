import Foundation

@MainActor
final class SubscriptionsViewModel: ObservableObject {
    @Published var subscriptions: [Subscription] = []
    @Published var feedVideos: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    private var feedStart = 0
    private var feedTotal: Int?
    private var apiClient: PeerTubeAPIClient?

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
            async let subs: PaginatedResponse<Subscription> = apiClient.request(
                .mySubscriptions(start: 0, count: 50)
            )
            async let feed: PaginatedResponse<Video> = apiClient.request(
                .mySubscriptionVideos(start: 0, count: pageSize, sort: "-publishedAt")
            )
            let (subsResp, feedResp) = try await (subs, feed)
            subscriptions = subsResp.items
            feedVideos = feedResp.items
            feedStart = feedResp.items.count
            feedTotal = feedResp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreFeed() async {
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
}
