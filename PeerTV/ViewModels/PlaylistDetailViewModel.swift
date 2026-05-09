import Foundation
import os

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    private static let log = Logger(subsystem: "com.peernext.PeerTV", category: "PlaylistDetail")
    @Published var playlist: VideoPlaylist?
    @Published var elements: [PlaylistElement] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var accountChannels: [VideoChannel] = []
    /// From `GET /api/v1/video-playlists/privacies` (PeerTube only exposes 1–3 for playlists, never video-only “internal” 4).
    @Published private(set) var playlistPrivacyMenuItems: [VideoPlaylistPrivacyMenuItem] = [
        .init(id: 1, label: "Public"),
        .init(id: 2, label: "Unlisted"),
        .init(id: 3, label: "Private"),
    ]

    private let pageSize = 15
    private var currentStart = 0
    private var total: Int?
    private var apiClient: PeerTubeAPIClient?
    private var accountName: String?
    let playlistId: Int
    /// URL path segment for `/api/v1/video-playlists/{…}` (prefer UUID from list/detail for unlisted/private).
    private var playlistPathId: String

    init(playlistId: Int, initialPlaylistPathId: String? = nil) {
        self.playlistId = playlistId
        if let p = initialPlaylistPathId?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            self.playlistPathId = p
        } else {
            self.playlistPathId = "\(playlistId)"
        }
    }

    func configure(apiClient: PeerTubeAPIClient, accountName: String? = nil) {
        self.apiClient = apiClient
        self.accountName = accountName
    }

    private static let fallbackPlaylistPrivacyMenuItems: [VideoPlaylistPrivacyMenuItem] = [
        .init(id: 1, label: "Public"),
        .init(id: 2, label: "Unlisted"),
        .init(id: 3, label: "Private"),
    ]

    /// Loads the instance’s supported playlist privacy levels (excludes video-only values such as internal `4`).
    func refreshPlaylistPrivacyMenuItems() async {
        guard let apiClient else { return }
        do {
            let dict: [String: String] = try await apiClient.request(.videoPlaylistPrivacies)
            let items: [VideoPlaylistPrivacyMenuItem] = dict.compactMap { key, label in
                guard let id = Int(key) else { return nil }
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = trimmed.isEmpty ? "Privacy \(id)" : trimmed
                return VideoPlaylistPrivacyMenuItem(id: id, label: title)
            }.sorted { $0.id < $1.id }
            if !items.isEmpty {
                playlistPrivacyMenuItems = items
            } else {
                playlistPrivacyMenuItems = Self.fallbackPlaylistPrivacyMenuItems
            }
        } catch {
            Self.log.notice("refreshPlaylistPrivacyMenuItems failed, using fallback: \(error.localizedDescription, privacy: .public)")
            playlistPrivacyMenuItems = Self.fallbackPlaylistPrivacyMenuItems
        }
    }

    /// Channels owned by the signed-in account (for publishing a playlist as public).
    func loadAccountChannels() async {
        guard let apiClient, let name = accountName, !name.isEmpty else {
            accountChannels = []
            return
        }
        errorMessage = nil
        do {
            let response: PaginatedResponse<VideoChannel> = try await apiClient.request(
                .accountVideoChannels(name: name, start: 0, count: 100)
            )
            accountChannels = response.items
        } catch {
            accountChannels = []
            errorMessage = error.localizedDescription
        }
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

        var pathRetryConsumed = false

        func loadInitialPage() async throws {
            playlist = try await apiClient.request(.playlistDetail(playlistPathId: playlistPathId))
            adoptResolvedPlaylistPathId(from: playlist)
            let resp: PaginatedResponse<PlaylistElement> = try await apiClient.request(
                .playlistVideos(playlistPathId: playlistPathId, start: 0, count: pageSize)
            )
            elements = resp.items
            currentStart = resp.items.count
            total = resp.total
        }

        do {
            try await loadInitialPage()
        } catch {
            let is404 = (error as? APIError).map { err -> Bool in
                if case .httpError(404, _) = err { return true }
                return false
            } == true
            if is404, !pathRetryConsumed, await resolvePlaylistPathIdViaAccountList() {
                pathRetryConsumed = true
                Self.log.notice("Retrying playlist load after resolving path id playlistNumericId=\(self.playlistId, privacy: .public)")
                do {
                    try await loadInitialPage()
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func adoptResolvedPlaylistPathId(from pl: VideoPlaylist?) {
        guard let pl, let resolved = pl.peertubePlaylistPathId else { return }
        if resolved != playlistPathId {
            Self.log.notice("Playlist API path id updated: \(self.playlistPathId, privacy: .public) → \(resolved, privacy: .public)")
        }
        playlistPathId = resolved
    }

    /// After `GET …/video-playlists/{numeric}` returns 404 for non-public playlists, find the same playlist on the signed-in account and use its UUID in the path.
    private func resolvePlaylistPathIdViaAccountList() async -> Bool {
        guard let apiClient, let name = accountName, !name.isEmpty else { return false }
        var start = 0
        let batch = 100
        while true {
            let resp: PaginatedResponse<VideoPlaylist>
            do {
                resp = try await apiClient.request(.accountPlaylists(name: name, start: start, count: batch))
            } catch {
                Self.log.error("resolvePlaylistPathIdViaAccountList failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
            if let found = resp.items.first(where: { $0.id == playlistId }),
               let path = found.peertubePlaylistPathId {
                playlistPathId = path
                return true
            }
            let pageCount = resp.items.count
            start += pageCount
            if pageCount == 0 { break }
            if let total = resp.total, start >= total { break }
        }
        return false
    }

    func loadMore() async {
        guard let apiClient, !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let resp: PaginatedResponse<PlaylistElement> = try await apiClient.request(
                .playlistVideos(playlistPathId: playlistPathId, start: currentStart, count: pageSize)
            )
            elements.append(contentsOf: resp.items)
            currentStart += resp.items.count
            total = resp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Updates playlist privacy (multipart `PUT`, per PeerTube). Public requires `videoChannelId` (existing or chosen).
    func updatePlaylistPrivacy(privacyId: Int, videoChannelId: Int?) async -> Bool {
        guard let apiClient, let pl = playlist else { return false }
        errorMessage = nil
        let allowedPrivacyIds = Set(playlistPrivacyMenuItems.map(\.id))
        guard allowedPrivacyIds.contains(privacyId) else {
            errorMessage = "That privacy level is not supported for playlists on this server."
            Self.log.notice("updatePlaylistPrivacy rejected unsupported privacyId=\(privacyId, privacy: .public) allowed=\(Array(allowedPrivacyIds).sorted(), privacy: .public)")
            return false
        }
        let channelToSend: Int?
        if privacyId == 1 {
            channelToSend = videoChannelId ?? pl.videoChannel?.id
            guard channelToSend != nil else {
                errorMessage = "Choose a channel for a public playlist."
                return false
            }
        } else {
            channelToSend = nil
        }
        let displayName = pl.displayName ?? ""
        Self.log.notice(
            "updatePlaylistPrivacy start playlistId=\(self.playlistId, privacy: .public) privacyId=\(privacyId, privacy: .public) channelToSend=\(channelToSend.map(String.init) ?? "nil", privacy: .public) playlistChannelId=\(pl.videoChannel?.id.map(String.init) ?? "nil", privacy: .public) displayNameEmpty=\(displayName.isEmpty, privacy: .public)"
        )
        isLoading = true
        defer { isLoading = false }
        do {
            try await apiClient.updateVideoPlaylist(
                playlistPathId: playlistPathId,
                displayName: displayName,
                description: pl.description,
                privacy: privacyId,
                videoChannelId: channelToSend
            )
            Self.log.notice("updatePlaylistPrivacy succeeded playlistId=\(self.playlistId, privacy: .public)")
            await loadInitial()
            NotificationCenter.default.post(name: .peerTVPlaylistsNeedRefresh, object: nil)
            return true
        } catch {
            if let api = error as? APIError, case .httpError(let code, let data) = api {
                let preview = String(data: data, encoding: .utf8).map { s in
                    s.count > 512 ? String(s.prefix(512)) + "…" : s
                } ?? "<non-utf8 \(data.count) bytes>"
                Self.log.error("updatePlaylistPrivacy HTTP failure status=\(code, privacy: .public) bodyPreview=\(preview, privacy: .public)")
            } else {
                Self.log.error("updatePlaylistPrivacy failed: \(String(describing: error), privacy: .public) localized=\(error.localizedDescription, privacy: .public)")
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Deletes the playlist on the server. Returns `true` when the API call succeeded.
    func deletePlaylist() async -> Bool {
        guard let apiClient else { return false }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await apiClient.rawRequest(.deletePlaylist(playlistPathId: playlistPathId))
            NotificationCenter.default.post(name: .peerTVPlaylistsNeedRefresh, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removePlaylistElement(_ element: PlaylistElement) async {
        guard let apiClient, let elementId = element.id else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await apiClient.rawRequest(.removePlaylistElement(playlistPathId: playlistPathId, elementId: elementId))
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
                    .playlistVideos(playlistPathId: playlistPathId, start: start, count: batchSize)
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
                    playlistPathId: playlistPathId,
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

