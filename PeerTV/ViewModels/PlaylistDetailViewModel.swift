import Foundation

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published var playlist: VideoPlaylist?
    @Published var elements: [PlaylistElement] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    let playlistId: Int

    init(playlistId: Int) {
        self.playlistId = playlistId
    }

    func configure(apiClient: PeerTubeAPIClient) {
        self.apiClient = apiClient
    }

    var canLoadMore: Bool {
        guard let total else { return true }
        return currentStart < total
    }

    /// Total entries in the playlist (from playlist metadata or pagination total).
    var totalVideoCount: Int {
        if let len = playlist?.videosLength { return len }
        if let total { return total }
        return elements.count
    }

    func loadInitial() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            playlist = try await apiClient.request(.playlistDetail(id: playlistId))
            let resp: PaginatedResponse<PlaylistElement> = try await apiClient.request(
                .playlistVideos(id: playlistId, start: 0, count: pageSize)
            )
            elements = resp.items
            currentStart = resp.items.count
            total = resp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let apiClient, !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let resp: PaginatedResponse<PlaylistElement> = try await apiClient.request(
                .playlistVideos(id: playlistId, start: currentStart, count: pageSize)
            )
            elements.append(contentsOf: resp.items)
            currentStart += resp.items.count
            total = resp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removePlaylistElement(_ element: PlaylistElement) async {
        guard let apiClient, let elementId = element.id else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await apiClient.rawRequest(.removePlaylistElement(playlistId: playlistId, elementId: elementId))
            await loadInitial()
            NotificationCenter.default.post(name: .peerTVPlaylistsNeedRefresh, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches all video IDs in this playlist (paginated) for bulk download / removal.
    func loadAllPlaylistVideoIds() async -> [String] {
        guard let apiClient else { return [] }
        var allIds: [String] = []
        var start = 0
        let batchSize = 100
        while true {
            do {
                let resp: PaginatedResponse<PlaylistElement> = try await apiClient.request(
                    .playlistVideos(id: playlistId, start: start, count: batchSize)
                )
                let ids = resp.items.compactMap { $0.video?.stableId }
                allIds.append(contentsOf: ids)
                start += resp.items.count
                let totalCount = resp.total ?? Int.max
                if resp.items.isEmpty || start >= totalCount { break }
            } catch {
                break
            }
        }
        return allIds
    }

    /// PeerTube: move the block at `startPosition` so it sits after `insertAfterPosition` (0 = before first).
    func reorderPlaylist(startPosition: Int, insertAfterPosition: Int, reorderLength: Int = 1) async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await apiClient.rawRequest(
                .reorderPlaylistVideos(
                    playlistId: playlistId,
                    startPosition: startPosition,
                    insertAfterPosition: insertAfterPosition,
                    reorderLength: reorderLength
                )
            )
            await loadInitial()
            NotificationCenter.default.post(name: .peerTVPlaylistsNeedRefresh, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveElementUp(_ element: PlaylistElement) async {
        guard let p = element.position, p >= 2 else { return }
        let insertAfter = max(0, p - 2)
        await reorderPlaylist(startPosition: p, insertAfterPosition: insertAfter)
    }

    func moveElementDown(_ element: PlaylistElement) async {
        guard let p = element.position, p < totalVideoCount else { return }
        await reorderPlaylist(startPosition: p, insertAfterPosition: p)
    }

    func canMoveUp(_ element: PlaylistElement) -> Bool {
        guard let p = element.position else { return false }
        return p >= 2
    }

    func canMoveDown(_ element: PlaylistElement) -> Bool {
        guard let p = element.position else { return false }
        return p < totalVideoCount
    }

    /// Applies one reorder from a local draft (loaded page only). Skips the network call if the item index is unchanged.
    func commitDraftReorder(
        movedElementId: Int,
        originalStartPosition: Int,
        originalIndex: Int,
        draft: [PlaylistElement]
    ) async {
        guard let idx = draft.firstIndex(where: { $0.id == movedElementId }) else { return }
        if idx == originalIndex { return }
        let insertAfter: Int
        if idx == 0 {
            insertAfter = 0
        } else {
            guard let prevPos = draft[idx - 1].position else {
                errorMessage = "Could not read playlist order. Try again after the list finishes loading."
                return
            }
            insertAfter = prevPos
        }
        await reorderPlaylist(startPosition: originalStartPosition, insertAfterPosition: insertAfter)
    }
}

