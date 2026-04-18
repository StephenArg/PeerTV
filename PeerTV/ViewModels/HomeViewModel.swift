import Foundation
import os

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
    private static let log = Logger(subsystem: "com.peernext.PeerTV", category: "HomeViewModel")

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
    /// Broad privacy/`include` on global `/videos` — only for admin/moderator on most instances.
    private var includeAllPrivacy = false

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

    func configure(apiClient: PeerTubeAPIClient, isAuthenticated: Bool, includeAllPrivacy: Bool) {
        self.apiClient = apiClient
        self.isAuthenticated = isAuthenticated
        self.includeAllPrivacy = includeAllPrivacy
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
            // Normal users: omit broad filters (many instances 401). Admin/moderator: may use all privacies per API.
            let response: PaginatedResponse<Video> = try await apiClient.request(
                .videos(sort: sort, start: currentStart, count: pageSize, includeAllPrivacy: includeAllPrivacy)
            )
            total = response.total
            let existingIds = Set(videos.map(\.stableId))
            let unique = response.items.filter { !existingIds.contains($0.stableId) }
            videos.append(contentsOf: unique)
            currentStart += response.items.count
        } catch {
            Self.log.error("loadMore failed sort=\(self.sort, privacy: .public) authenticated=\(self.isAuthenticated) includeAllPrivacy=\(self.includeAllPrivacy) start=\(self.currentStart) error=\(error.localizedDescription, privacy: .public) underlying=\(String(describing: error), privacy: .public)")
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
