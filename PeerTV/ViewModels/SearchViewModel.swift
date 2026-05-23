import Foundation

enum SearchMode: String, CaseIterable, Identifiable {
    case instance = "This instance"
    case global = "Sepia Search"

    var id: String { rawValue }

    var searchScope: SearchVideosScope {
        switch self {
        case .instance: return .instance
        case .global: return .global
        }
    }

    var emptyStateMessage: String {
        switch self {
        case .instance:
            return "Search for videos across this instance"
        case .global:
            return "Search videos across the PeerTube network via Sepia Search"
        }
    }
}

struct SearchSuggestion: Identifiable, Hashable {
    let id: String
    let title: String
    let query: String
    let subtitle: String?
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var results: [Video] = []
    @Published var suggestions: [SearchSuggestion] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var mode: SearchMode = .instance

    private let pageSize = 15
    private let suggestionCount = 8
    private let searchDebounceNanoseconds: UInt64 = 1_000_000_000
    private let suggestionDebounceNanoseconds: UInt64 = 350_000_000

    private var currentStart = 0
    private var total: Int?
    private var instanceClient: PeerTubeAPIClient?
    private var globalClient: PeerTubeAPIClient { PeerTubeOriginClients.sepiaSearch }
    private(set) var activeQuery = ""

    private var searchDebounceTask: Task<Void, Never>?
    private var suggestionDebounceTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var suggestionGeneration = 0

    func configure(instanceClient: PeerTubeAPIClient) {
        self.instanceClient = instanceClient
    }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    func scheduleSearch(query: String) {
        searchDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear()
            return
        }
        scheduleSuggestions(query: query)
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await search(query: trimmed)
        }
    }

    func scheduleSuggestions(query: String) {
        suggestionDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            suggestions = []
            return
        }
        suggestionDebounceTask = Task {
            try? await Task.sleep(nanoseconds: suggestionDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await fetchSuggestions(query: trimmed)
        }
    }

    func modeDidChange(draftQuery: String) {
        searchDebounceTask?.cancel()
        suggestionDebounceTask?.cancel()
        let trimmed = draftQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmed.isEmpty ? activeQuery : trimmed
        guard !query.isEmpty else { return }
        scheduleSuggestions(query: query)
        scheduleSearch(query: query)
    }

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activeClient != nil else { return }

        let generation = searchGeneration + 1
        searchGeneration = generation
        let searchMode = mode

        activeQuery = trimmed
        currentStart = 0
        results = []
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let response: PaginatedResponse<Video> = try await activeClient!.request(
                .searchVideos(
                    search: trimmed,
                    start: 0,
                    count: pageSize,
                    scope: mode.searchScope
                )
            )
            guard searchGeneration == generation, activeQuery == trimmed, mode == searchMode else { return }
            total = response.total
            results = response.items
            currentStart = response.items.count
            suggestions = makeSuggestions(from: response.items, query: trimmed)
        } catch {
            guard searchGeneration == generation, activeQuery == trimmed else { return }
            errorMessage = error.localizedDescription
        }
    }

    func fetchSuggestions(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = activeClient else {
            suggestions = []
            return
        }

        let generation = suggestionGeneration + 1
        suggestionGeneration = generation
        let searchMode = mode

        do {
            let response: PaginatedResponse<Video> = try await client.request(
                .searchVideos(
                    search: trimmed,
                    start: 0,
                    count: suggestionCount,
                    scope: mode.searchScope
                )
            )
            guard suggestionGeneration == generation, mode == searchMode else { return }
            suggestions = makeSuggestions(from: response.items, query: trimmed)
        } catch {
            guard suggestionGeneration == generation else { return }
            suggestions = []
        }
    }

    func loadMore() async {
        guard let client = activeClient, !isLoading, canLoadMore, !activeQuery.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let scope = mode.searchScope
        do {
            let response: PaginatedResponse<Video> = try await client.request(
                .searchVideos(
                    search: activeQuery,
                    start: currentStart,
                    count: pageSize,
                    scope: scope
                )
            )
            total = response.total
            let existingIds = Set(results.map(\.stableId))
            let unique = response.items.filter { !existingIds.contains($0.stableId) }
            results.append(contentsOf: unique)
            currentStart += response.items.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        suggestionDebounceTask?.cancel()
        suggestionDebounceTask = nil
        searchGeneration += 1
        suggestionGeneration += 1
        activeQuery = ""
        results = []
        suggestions = []
        total = nil
        currentStart = 0
        errorMessage = nil
    }

    func playbackContext(
        for video: Video,
        accessToken: String?
    ) -> (client: PeerTubeAPIClient, accessToken: String?) {
        guard let instanceClient else {
            return PeerTubeOriginClients.playbackContext(
                for: video,
                mode: mode,
                instanceClient: globalClient,
                accessToken: nil
            )
        }
        return PeerTubeOriginClients.playbackContext(
            for: video,
            mode: mode,
            instanceClient: instanceClient,
            accessToken: accessToken
        )
    }

    private var activeClient: PeerTubeAPIClient? {
        switch mode {
        case .instance: return instanceClient
        case .global: return globalClient
        }
    }

    private func makeSuggestions(from videos: [Video], query: String) -> [SearchSuggestion] {
        var seen = Set<String>()
        var list: [SearchSuggestion] = []
        for video in videos {
            guard let title = video.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            let key = title.lowercased()
            guard seen.insert(key).inserted else { continue }
            let subtitle: String?
            if mode == .global, let host = video.originHost {
                subtitle = host
            } else {
                subtitle = video.channel?.displayName ?? video.account?.displayName
            }
            list.append(SearchSuggestion(
                id: video.stableId,
                title: title,
                query: title,
                subtitle: subtitle?.isEmpty == false ? subtitle : nil
            ))
            if list.count >= suggestionCount { break }
        }
        if list.isEmpty, !query.isEmpty {
            list.append(SearchSuggestion(id: "query-\(query)", title: query, query: query, subtitle: nil))
        }
        return list
    }
}
