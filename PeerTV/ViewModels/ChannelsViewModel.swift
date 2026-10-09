import Foundation

/// `sort` values for `GET /api/v1/video-channels`. "This server only" goes through the channel
/// search route, which only sorts by `-createdAt`, so that mode is pinned to `newest`.
enum ChannelListSort: String, CaseIterable, Identifiable {
    case newest = "-createdAt"
    case recentlyActive = "-updatedAt"
    case name = "name"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newest: "Newest"
        case .recentlyActive: "Recently Active"
        case .name: "Name"
        }
    }

    /// Order shown in the sort dialog.
    static let dialogOrder: [ChannelListSort] = [.newest, .recentlyActive, .name]
}

@MainActor
final class ChannelsViewModel: ObservableObject {
    @Published var channels: [VideoChannel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var sort: ChannelListSort
    /// Only channels hosted on the connected server, instead of every one it knows about.
    @Published private(set) var localOnly: Bool

    private static let sortDefaultsKey = "PeerTV.channelsSort"
    private static let localOnlyDefaultsKey = "PeerTV.channelsLocalOnly"

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    private var instanceHost: String?
    /// Set while `refreshInPlace` runs. Kept off `isLoading` so the spinner doesn't flash.
    private var isRefreshing = false
    /// A page requested while a refresh was replacing the list; loaded once the refresh lands.
    private var loadMoreDeferred = false
    /// Bumped by `loadInitial()`. Requests started under an older generation drop their results,
    /// so a sort or scope change never shows rows fetched for the previous list.
    private var loadGeneration = 0

    init() {
        sort = UserDefaults.standard.string(forKey: Self.sortDefaultsKey)
            .flatMap(ChannelListSort.init(rawValue:)) ?? .newest
        localOnly = UserDefaults.standard.bool(forKey: Self.localOnlyDefaultsKey)
    }

    func configure(apiClient: PeerTubeAPIClient, instanceHost: String?) {
        self.apiClient = apiClient
        self.instanceHost = instanceHost
    }

    /// Sorting is only available for the all-servers list (see `ChannelListSort`).
    var showsSortControls: Bool { !localOnly }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    private func listEndpoint(start: Int, count: Int) -> Endpoint {
        if localOnly, let instanceHost, !instanceHost.isEmpty {
            return .searchVideoChannels(
                search: nil,
                host: instanceHost,
                start: start,
                count: count,
                sort: ChannelListSort.newest.rawValue
            )
        }
        return .videoChannels(start: start, count: count, sort: sort.rawValue)
    }

    func loadInitial() async {
        loadGeneration += 1
        currentStart = 0
        channels = []
        total = nil
        isLoading = false
        await loadMore()
    }

    /// First load only — avoids wiping scroll position when the view reappears (e.g. after coming back from a channel).
    func loadInitialIfEmpty() async {
        guard channels.isEmpty else { return }
        await loadInitial()
    }

    func applySort(_ option: ChannelListSort) async {
        guard option != sort else { return }
        sort = option
        UserDefaults.standard.set(option.rawValue, forKey: Self.sortDefaultsKey)
        guard !localOnly else { return }
        await loadInitial()
    }

    func applyLocalOnly(_ enabled: Bool) async {
        guard enabled != localOnly else { return }
        localOnly = enabled
        UserDefaults.standard.set(enabled, forKey: Self.localOnlyDefaultsKey)
        await loadInitial()
    }

    /// Refetches the rows already loaded without clearing the list first, so scroll position and
    /// focus survive. On failure the rows on screen are kept.
    func refreshInPlace() async {
        guard let apiClient, !isLoading, !isRefreshing else { return }
        isRefreshing = true
        let generation = loadGeneration
        // Refetch as many rows as are already loaded so a deep scroll position still exists.
        let count = min(max(pageSize, channels.count), 100)
        do {
            let response: PaginatedResponse<VideoChannel> = try await apiClient.request(
                listEndpoint(start: 0, count: count)
            )
            if generation == loadGeneration {
                let fresh = response.items
                let freshIds = Set(fresh.compactMap(\.id))
                // A request returns at most 100 rows; rows loaded beyond that stay, after the fresh ones.
                channels = channels.count > count
                    ? fresh + channels.filter { channel in channel.id.map { !freshIds.contains($0) } ?? false }
                    : fresh
                total = response.total
                currentStart = max(response.items.count, channels.count)
                errorMessage = nil
            }
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
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let response: PaginatedResponse<VideoChannel> = try await apiClient.request(
                listEndpoint(start: currentStart, count: pageSize)
            )
            guard generation == loadGeneration else { return }
            total = response.total
            channels.append(contentsOf: response.items)
            currentStart += response.items.count
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Channel search

@MainActor
final class ChannelSearchViewModel: ObservableObject {
    @Published var results: [VideoChannel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    private(set) var activeQuery = ""

    private let pageSize = 15
    private let searchDebounceNanoseconds: UInt64 = 1_000_000_000
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    /// When set, results are limited to channels hosted there ("this server only").
    private var host: String?
    private var debounceTask: Task<Void, Never>?
    private var searchGeneration = 0

    func configure(apiClient: PeerTubeAPIClient, host: String?) {
        self.apiClient = apiClient
        self.host = host
    }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    func scheduleSearch(query: String) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear()
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await search(query: trimmed)
        }
    }

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let apiClient else { return }

        searchGeneration += 1
        let generation = searchGeneration
        activeQuery = trimmed
        currentStart = 0
        results = []
        errorMessage = nil
        isLoading = true
        defer { if generation == searchGeneration { isLoading = false } }

        do {
            let response: PaginatedResponse<VideoChannel> = try await apiClient.request(
                .searchVideoChannels(search: trimmed, host: host, start: 0, count: pageSize, sort: "-match")
            )
            guard generation == searchGeneration else { return }
            total = response.total
            results = response.items
            currentStart = response.items.count
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let apiClient, !isLoading, canLoadMore, !activeQuery.isEmpty else { return }
        let generation = searchGeneration
        isLoading = true
        defer { if generation == searchGeneration { isLoading = false } }

        do {
            let response: PaginatedResponse<VideoChannel> = try await apiClient.request(
                .searchVideoChannels(search: activeQuery, host: host, start: currentStart, count: pageSize, sort: "-match")
            )
            guard generation == searchGeneration else { return }
            total = response.total
            let existingIds = Set(results.compactMap(\.id))
            results.append(contentsOf: response.items.filter { channel in
                channel.id.map { !existingIds.contains($0) } ?? true
            })
            currentStart += response.items.count
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        searchGeneration += 1
        activeQuery = ""
        results = []
        total = nil
        currentStart = 0
        errorMessage = nil
    }
}
