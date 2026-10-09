import Foundation
import os

/// API `sort` values for `GET /api/v1/videos` (see PeerTube REST docs).
enum HomeVideoListSort: String, CaseIterable, Identifiable {
    case recentlyAdded = "-publishedAt"
    case name = "name"
    case trending = "-trending"
    case hot = "-hot"
    case mostViewed = "-views"
    case mostLiked = "-likes"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .name: "Name"
        case .trending: "Trending"
        case .hot: "Hot"
        case .mostViewed: "Most Viewed"
        case .mostLiked: "Most Liked"
        }
    }

    /// Order shown in the home sort dialog.
    static let dialogOrder: [HomeVideoListSort] = [.recentlyAdded, .name, .trending, .hot, .mostViewed, .mostLiked]
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
    @Published private(set) var categoryMenuItems: [VideoCategoryMenuItem] = []
    /// Languages for the Filters sheet: the widely used ones first (`FediverseHotLanguage` order),
    /// then the rest of the server's list alphabetically.
    @Published private(set) var commonLanguageMenuItems: [VideoLanguageMenuItem] = []
    @Published private(set) var otherLanguageMenuItems: [VideoLanguageMenuItem] = []
    @Published private(set) var filters = HomeVideoFilters()

    private static let sortDefaultsKey = "PeerTV.homeVideoSort"
    private static let scopeDefaultsKey = "PeerTV.homeVideoScope"

    private let pageSize = 15
    /// With a language filter the server's pages are thinned client-side (see
    /// `matchesLanguageFilter`), so ask for bigger ones and fetch several per load.
    private let languageFilterPageSize = 50
    private let languageFilterMaxPagesPerLoad = 4
    /// Rows consumed from the server so far (not rows on screen: a language filter drops some).
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    private var isAuthenticated = false
    /// Broad privacy/`include` on global `/videos` — only for admin/moderator on most instances.
    private var includeAllPrivacy = false
    private var fediverseHotLoaded = false
    private var fediverseRowEnrichmentInFlight = Set<String>()
    /// Bumped by `loadInitial()`. Requests started under an older generation drop their results,
    /// so a sort/scope/category change never shows rows fetched for the previous list.
    private var loadGeneration = 0

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
        filters = HomeVideoFilters(
            categoryIds: Set(HomeVideoCategoryFilter.loadSavedIds()),
            languageIds: Set(HomeVideoLanguageFilter.loadSavedIds()),
            includeSubtitled: HomeVideoLanguageFilter.loadIncludeSubtitled(),
            live: HomeLiveFilter.loadSaved()
        )
    }

    var fediverseLanguageButtonTitle: String {
        fediverseLanguageIds.isEmpty ? "Languages" : "Languages (\(fediverseLanguageIds.count))"
    }

    var filtersButtonTitle: String {
        filters.isEmpty ? "Filters" : "Filters (\(filters.activeCount))"
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

    var showsFilterControls: Bool {
        currentListScope != .fediverseTrending
    }

    /// True once the current list has loaded and come back empty, so the grid can say why
    /// instead of showing nothing. False while loading, after an error, and before the first load.
    var isEmptyAfterLoad: Bool {
        guard videos.isEmpty, !isLoading, errorMessage == nil else { return false }
        return currentListScope == .fediverseTrending ? fediverseHotLoaded : total != nil
    }

    /// The selected Fediverse languages by name, for the empty state ("Spanish and Arabic").
    var fediverseLanguageNames: String {
        let names = fediverseLanguageIds.compactMap { FediverseHotLanguage(rawValue: $0)?.displayName }
        return ListFormatter.localizedString(byJoining: names)
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
        loadGeneration += 1
        currentStart = 0
        videos = []
        fediverseHotLoaded = false
        total = nil
        isLoading = false
        await loadMore()
    }

    /// First load only — avoids wiping scroll position when the view reappears (e.g. after closing the player).
    func loadInitialIfEmpty() async {
        guard videos.isEmpty else { return }
        await loadInitial()
    }

    /// Refetches the list without clearing it first, so scroll position and focus survive when the
    /// same videos come back. On failure the existing rows are kept.
    func refreshInPlace() async {
        guard !videos.isEmpty else {
            await loadInitial()
            return
        }
        guard !isLoading else { return }
        let generation = loadGeneration

        if currentListScope == .fediverseTrending {
            isLoading = true
            defer { if generation == loadGeneration { isLoading = false } }
            do {
                let loaded = try await FediverseHotVideosResponse.fetchVideos(languageIds: fediverseLanguageIds)
                guard generation == loadGeneration else { return }
                videos = carryingOverEnrichment(into: loaded)
                fediverseHotLoaded = true
                total = loaded.count
                currentStart = loaded.count
            } catch {
                Self.log.notice("refreshInPlace fediverse failed error=\(error.localizedDescription, privacy: .public)")
            }
            return
        }

        guard let apiClient else { return }
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        // Refetch as many rows as were consumed (API max 100) so a deep scroll position still exists.
        let count = min(max(pageSize, currentStart), 100)
        do {
            let response: PaginatedResponse<Video> = try await apiClient.request(
                .videos(
                    sort: sort,
                    start: 0,
                    count: count,
                    includeAllPrivacy: includeAllPrivacy,
                    isLocal: currentListScope.isLocal,
                    categoryIds: filters.categoryIds.sorted(),
                    languageIds: filters.languageIds.sorted(),
                    isLive: filters.live.isLive
                )
            )
            guard generation == loadGeneration else { return }
            var seen = Set<String>()
            videos = response.items.filter { seen.insert($0.stableId).inserted && matchesLanguageFilter($0) }
            total = response.total
            currentStart = response.items.count
            errorMessage = nil
        } catch {
            Self.log.notice("refreshInPlace failed sort=\(self.sort, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rows already on screen won't re-trigger `enrichFediverseRow`, so keep what they already fetched.
    private func carryingOverEnrichment(into loaded: [Video]) -> [Video] {
        let previous = Dictionary(videos.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
        return loaded.map { video in
            guard let old = previous[video.stableId] else { return video }
            return video.withEnrichedMetadata(
                views: video.views ?? old.views,
                avatars: old.channel?.avatars,
                thumbnailPath: old.thumbnailPath
            )
        }
    }

    func loadMore() async {
        if currentListScope == .fediverseTrending {
            await loadFediverseHotIfNeeded()
            return
        }
        guard let apiClient, !isLoading, canLoadMore else { return }
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            // A spoken-language filter thins each page client-side, so keep fetching until a
            // page's worth is on screen or the list ends; otherwise one request is enough.
            let thinsPages = !filters.languageIds.isEmpty && !filters.includeSubtitled
            var added = 0
            var pagesFetched = 0
            repeat {
                // Normal users: omit broad filters (many instances 401). Admin/moderator: may use all privacies per API.
                let response: PaginatedResponse<Video> = try await apiClient.request(
                    .videos(
                        sort: sort,
                        start: currentStart,
                        count: thinsPages ? languageFilterPageSize : pageSize,
                        includeAllPrivacy: includeAllPrivacy,
                        isLocal: currentListScope.isLocal,
                        categoryIds: filters.categoryIds.sorted(),
                        languageIds: filters.languageIds.sorted(),
                        isLive: filters.live.isLive
                    )
                )
                guard generation == loadGeneration else { return }
                total = response.total
                let existingIds = Set(videos.map(\.stableId))
                let unique = response.items.filter { !existingIds.contains($0.stableId) && matchesLanguageFilter($0) }
                videos.append(contentsOf: unique)
                currentStart += response.items.count
                added += unique.count
                pagesFetched += 1
                if response.items.isEmpty { break }
            } while thinsPages && added < pageSize && canLoadMore && pagesFetched < languageFilterMaxPagesPerLoad
        } catch {
            guard generation == loadGeneration else { return }
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

    /// Loads the server's category and language lists for the Filters sheet, and drops saved
    /// selections the server no longer offers.
    func refreshFilterMenuItems() async {
        guard let apiClient else { return }
        async let categoriesResult = Self.fetchCategoryMenuItems(apiClient: apiClient)
        async let languagesResult = Self.fetchLanguageMenuItems(apiClient: apiClient)

        var pruned = filters
        if let categories = await categoriesResult {
            categoryMenuItems = categories
            pruned.categoryIds = filters.categoryIds.intersection(categories.map(\.id))
        } else {
            categoryMenuItems = []
        }
        if let languages = await languagesResult {
            (commonLanguageMenuItems, otherLanguageMenuItems) = Self.splitLanguages(languages)
            pruned.languageIds = filters.languageIds.intersection(languages.map(\.id) + [VideoLanguageMenuItem.unspecified.id])
        } else {
            // No server list: the widely used languages are still worth offering.
            commonLanguageMenuItems = FediverseHotLanguage.allInOrder.map {
                VideoLanguageMenuItem(id: $0.rawValue, label: $0.displayName)
            } + [.unspecified]
            otherLanguageMenuItems = []
        }
        if pruned != filters {
            filters = pruned
            saveFilters()
        }
    }

    /// PeerTube's `languageOneOf` also returns videos that merely have *subtitles* in a selected
    /// language, so "Italian" brings back English videos with Italian captions. Unless the
    /// filters ask for those, keep only videos whose own language is selected; "Not specified"
    /// keeps the ones with none.
    func matchesLanguageFilter(_ video: Video) -> Bool {
        let selected = filters.languageIds
        guard !selected.isEmpty, !filters.includeSubtitled else { return true }
        guard let languageId = video.languageId else {
            return selected.contains(VideoLanguageMenuItem.unspecified.id)
        }
        return selected.contains(languageId)
    }

    /// Replaces the filters, and reloads the grid when a different set of videos results.
    func applyFilters(_ newFilters: HomeVideoFilters) async {
        guard newFilters != filters else { return }
        let sameVideos = newFilters.selectsSameVideos(as: filters)
        filters = newFilters
        saveFilters()
        guard !sameVideos, currentListScope != .fediverseTrending else { return }
        await loadInitial()
    }

    private func saveFilters() {
        HomeVideoCategoryFilter.saveIds(filters.categoryIds.sorted())
        HomeVideoLanguageFilter.saveIds(filters.languageIds.sorted())
        HomeVideoLanguageFilter.saveIncludeSubtitled(filters.includeSubtitled)
        HomeLiveFilter.save(filters.live)
    }

    private static func fetchCategoryMenuItems(apiClient: PeerTubeAPIClient) async -> [VideoCategoryMenuItem]? {
        do {
            let dict: [String: String] = try await apiClient.request(.videoCategories)
            return dict.compactMap { key, label in
                guard let id = Int(key) else { return nil }
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = trimmed.isEmpty ? "Category \(id)" : trimmed
                return VideoCategoryMenuItem(id: id, label: title)
            }.sorted { $0.id < $1.id }
        } catch {
            log.notice("fetchCategoryMenuItems failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func fetchLanguageMenuItems(apiClient: PeerTubeAPIClient) async -> [VideoLanguageMenuItem]? {
        do {
            let dict: [String: String] = try await apiClient.request(.videoLanguages)
            return dict.compactMap { key, label in
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !trimmed.isEmpty else { return nil }
                return VideoLanguageMenuItem(id: key, label: trimmed)
            }
        } catch {
            log.notice("fetchLanguageMenuItems failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Widely used languages first, in `FediverseHotLanguage` order, then "Not specified" (the
    /// server's list never includes it), then the rest by name.
    private static func splitLanguages(_ languages: [VideoLanguageMenuItem]) -> (common: [VideoLanguageMenuItem], other: [VideoLanguageMenuItem]) {
        let byId = Dictionary(languages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let commonIds = FediverseHotLanguage.allInOrder.map(\.rawValue)
        let common = commonIds.compactMap { byId[$0] } + [.unspecified]
        let commonSet = Set(commonIds + [VideoLanguageMenuItem.unspecified.id])
        let other = languages
            .filter { !commonSet.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return (common, other)
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
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let loaded = try await FediverseHotVideosResponse.fetchVideos(languageIds: fediverseLanguageIds)
            guard generation == loadGeneration else { return }
            videos = loaded
            fediverseHotLoaded = true
            total = loaded.count
            currentStart = loaded.count
        } catch {
            guard generation == loadGeneration else { return }
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
