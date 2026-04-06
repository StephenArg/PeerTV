import Foundation

/// API `sort` values for `GET /api/v1/videos` (see PeerTube REST docs).
enum HomeVideoListSort: String, CaseIterable, Identifiable {
    case recentlyAdded = "-publishedAt"
    case name = "name"
    case trending = "-trending"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .name: "Name"
        case .trending: "Trending"
        }
    }

    /// Order shown in the home sort dialog.
    static let dialogOrder: [HomeVideoListSort] = [.recentlyAdded, .name, .trending]
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var videos: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sort: String

    private static let sortDefaultsKey = "PeerTV.homeVideoSort"

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    private var isAuthenticated = false

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.sortDefaultsKey),
           HomeVideoListSort(rawValue: saved) != nil {
            sort = saved
        } else {
            sort = HomeVideoListSort.trending.rawValue
        }
    }

    var currentListSort: HomeVideoListSort {
        HomeVideoListSort(rawValue: sort) ?? .trending
    }

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

    func applyListSort(_ option: HomeVideoListSort) async {
        guard sort != option.rawValue else { return }
        sort = option.rawValue
        UserDefaults.standard.set(option.rawValue, forKey: Self.sortDefaultsKey)
        await loadInitial()
    }
}
