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

/// Selects which set of videos the home grid fetches from `GET /api/v1/videos`.
///
/// - `all`: omit the `isLocal` query parameter entirely — PeerTube returns the union of this
///   instance's videos and federated content (default behavior).
/// - `local`: request `isLocal=true` — only videos hosted on the currently connected instance.
enum HomeVideoScope: String, CaseIterable, Identifiable {
    case all
    case local
    case fediverseTrending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All platforms"
        case .local: "This server only"
        case .fediverseTrending: "Trending on Fediverse"
        }
    }

    /// Maps to the API's `isLocal` query value. `nil` means "don't send the parameter".
    var isLocal: Bool? {
        switch self {
        case .all: nil
        case .local: true
        case .fediverseTrending: nil
        }
    }

    /// Order shown in the home platforms dialog.
    static let dialogOrder: [HomeVideoScope] = [.all, .local, .fediverseTrending]
}

@MainActor
final class HomeViewModel: ObservableObject {
    private static let log = Logger(subsystem: "com.peernext.PeerTV", category: "HomeViewModel")

    @Published var videos: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sort: String
    @Published var scope: String
    @Published private(set) var fediverseLanguageIds: [String] = []

    private static let sortDefaultsKey = "PeerTV.homeVideoSort"
    private static let scopeDefaultsKey = "PeerTV.homeVideoScope"

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    private var isAuthenticated = false
    /// Broad privacy/`include` on global `/videos` — only for admin/moderator on most instances.
    private var includeAllPrivacy = false
    private var fediverseHotLoaded = false
    private var fediverseRowEnrichmentInFlight = Set<String>()

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.sortDefaultsKey),
           HomeVideoListSort(rawValue: saved) != nil {
            sort = saved
        } else {
            sort = HomeVideoListSort.trending.rawValue
        }
        if let saved = UserDefaults.standard.string(forKey: Self.scopeDefaultsKey),
           HomeVideoScope(rawValue: saved) != nil {
            scope = saved
        } else {
            scope = HomeVideoScope.all.rawValue
        }
        fediverseLanguageIds = FediverseHotLanguage.loadSavedCodes()
    }

    var fediverseLanguageButtonTitle: String {
        fediverseLanguageIds.isEmpty ? "Languages" : "Languages (\(fediverseLanguageIds.count))"
    }

    var currentListSort: HomeVideoListSort {
        HomeVideoListSort(rawValue: sort) ?? .trending
    }

    var currentListScope: HomeVideoScope {
        HomeVideoScope(rawValue: scope) ?? .all
    }

    var showsSortControls: Bool {
        currentListScope != .fediverseTrending
    }

    func configure(apiClient: PeerTubeAPIClient, isAuthenticated: Bool, includeAllPrivacy: Bool) {
        self.apiClient = apiClient
        self.isAuthenticated = isAuthenticated
        self.includeAllPrivacy = includeAllPrivacy
    }

    var canLoadMore: Bool {
        if currentListScope == .fediverseTrending {
            return !fediverseHotLoaded
        }
        guard let total else { return true }
        return currentStart < total
    }

    func loadInitial() async {
        currentStart = 0
        videos = []
        fediverseHotLoaded = false
        total = nil
        await loadMore()
    }

    /// First load only — avoids wiping scroll position when the view reappears (e.g. after closing the player).
    func loadInitialIfEmpty() async {
        guard videos.isEmpty else { return }
        await loadInitial()
    }

    func loadMore() async {
        if currentListScope == .fediverseTrending {
            await loadFediverseHotIfNeeded()
            return
        }
        guard let apiClient, !isLoading, canLoadMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Normal users: omit broad filters (many instances 401). Admin/moderator: may use all privacies per API.
            let response: PaginatedResponse<Video> = try await apiClient.request(
                .videos(
                    sort: sort,
                    start: currentStart,
                    count: pageSize,
                    includeAllPrivacy: includeAllPrivacy,
                    isLocal: currentListScope.isLocal
                )
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

    func applyFediverseLanguages(_ selection: Set<String>) async {
        let ordered = FediverseHotLanguage.orderedCodes(from: selection)
        guard ordered != fediverseLanguageIds else { return }
        fediverseLanguageIds = ordered
        FediverseHotLanguage.saveCodes(ordered)
        guard currentListScope == .fediverseTrending else { return }
        await loadInitial()
    }

    func applyListScope(_ option: HomeVideoScope) async {
        let scopeChanged = scope != option.rawValue
        if scopeChanged {
            scope = option.rawValue
            UserDefaults.standard.set(option.rawValue, forKey: Self.scopeDefaultsKey)
        }
        // Scope may already match (e.g. persisted pref) while `videos` is still empty — reload then.
        if scopeChanged || videos.isEmpty {
            await loadInitial()
        }
    }

    /// Anonymous home is fediverse-trending only; always fetch even when scope was already set in UserDefaults.
    func loadAnonymousFediverseHome() async {
        scope = HomeVideoScope.fediverseTrending.rawValue
        await loadInitial()
    }

    private func loadFediverseHotIfNeeded() async {
        guard !fediverseHotLoaded, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await FediverseHotVideosResponse.fetchVideos(languageIds: fediverseLanguageIds)
            videos = loaded
            fediverseHotLoaded = true
            total = loaded.count
            currentStart = loaded.count
        } catch {
            Self.log.error("loadFediverseHot failed error=\(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// Lazily loads the view count, channel avatar, and a working thumbnail for one trending row
    /// from its origin instance (the hot API omits views/avatars and serves thumbnails only from
    /// the index host). The media origin is tried first: it is authoritative and distinct per
    /// video, so requests fan out across hosts instead of all funneling through the index host.
    func enrichFediverseRow(for videoId: String) async {
        guard currentListScope == .fediverseTrending,
              let index = videos.firstIndex(where: { $0.stableId == videoId }) else { return }
        let needsAvatar = videos[index].channel?.avatars?.isEmpty != false
        let needsViews = videos[index].views == nil
        // Media origin first (fan-out + authoritative), index host (commentReadHost) as fallback.
        let hosts = [videos[index].originHost, videos[index].commentReadHost].compactMap { host -> String? in
            let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard needsAvatar || needsViews,
              !hosts.isEmpty,
              fediverseRowEnrichmentInFlight.insert(videoId).inserted else { return }
        defer { fediverseRowEnrichmentInFlight.remove(videoId) }

        let meta = await PeerTubeOriginClients.fetchVideoMetadata(videoId: videoId, hosts: hosts)
        guard meta.views != nil || meta.avatars != nil || meta.thumbnailURL != nil else { return }
        // Re-find the row after the await: a feed reload may have replaced the array, but as long
        // as the same video is still present we can apply the fetched data (avoids a wasted fetch).
        guard let freshIndex = videos.firstIndex(where: { $0.stableId == videoId }) else { return }
        videos[freshIndex] = videos[freshIndex].withEnrichedMetadata(
            views: meta.views,
            avatars: meta.avatars,
            thumbnailPath: meta.thumbnailURL
        )
    }
}
