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

    func loadMore() async {
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
