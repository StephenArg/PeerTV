import Foundation

@MainActor
final class PlaylistPickerViewModel: ObservableObject {
    static let addedMessage = "Video added to playlist"
    static let removedMessage = "Video removed from playlist"

    @Published var myPlaylists: [VideoPlaylist] = []
    @Published var myPlaylistsLoaded = false
    @Published var playlistElementByPlaylistId: [Int: Int] = [:]
    @Published var playlistMessage: String?

    /// Optional short label for contexts that show a compact toast (e.g. player transport bar).
    var onFeedback: ((String) -> Void)?

    private var apiClient: PeerTubeAPIClient?
    private var accountName: String?
    private var numericVideoId: Int?

    func configure(apiClient: PeerTubeAPIClient, accountName: String?, numericVideoId: Int?) {
        self.apiClient = apiClient
        self.accountName = accountName
        self.numericVideoId = numericVideoId
    }

    func loadMyPlaylists() async {
        myPlaylistsLoaded = false
        defer { myPlaylistsLoaded = true }
        guard let apiClient, let name = accountName, !name.isEmpty else {
            myPlaylists = []
            playlistElementByPlaylistId = [:]
            return
        }
        do {
            let response: PaginatedResponse<VideoPlaylist> = try await apiClient.request(
                .accountPlaylists(name: name, start: 0, count: 100)
            )
            myPlaylists = response.data ?? []
            await refreshPlaylistMembership()
        } catch {
            myPlaylists = []
            playlistElementByPlaylistId = [:]
        }
    }

    func isVideoInPlaylist(_ playlist: VideoPlaylist) -> Bool {
        guard let id = playlist.id else { return false }
        return playlistElementByPlaylistId[id] != nil
    }

    func togglePlaylistMembership(for playlist: VideoPlaylist) async {
        guard let pathId = playlist.peertubePlaylistPathId else { return }
        if let playlistId = playlist.id, let elementId = playlistElementByPlaylistId[playlistId] {
            await removeFromPlaylist(playlistPathId: pathId, elementId: elementId, playlistId: playlistId)
        } else {
            await addToPlaylist(playlistPathId: pathId)
        }
    }

    func createPlaylistAndAddVideo(displayName: String) async -> Result<Void, Error> {
        guard let apiClient else {
            return .failure(APIError.invalidInput("Not signed in."))
        }
        do {
            let playlistId = try await apiClient.createVideoPlaylist(displayName: displayName)
            await addToPlaylist(playlistPathId: "\(playlistId)")
            return .success(())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            notify(message)
            return .failure(error)
        }
    }

    private func refreshPlaylistMembership() async {
        guard let apiClient, let numericId = numericVideoId else {
            playlistElementByPlaylistId = [:]
            return
        }
        let existing: [String: [VideoPlaylistExistEntry]]? = try? await apiClient.request(
            .videosExistInPlaylists(videoIds: [numericId])
        )
        var map: [Int: Int] = [:]
        for entry in existing?["\(numericId)"] ?? [] {
            if let pid = entry.playlistId, let eid = entry.playlistElementId {
                map[pid] = eid
            }
        }
        playlistElementByPlaylistId = map
    }

    private func addToPlaylist(playlistPathId: String) async {
        guard let apiClient, let numericId = numericVideoId else { return }
        do {
            _ = try await apiClient.rawRequest(.addVideoToPlaylist(playlistPathId: playlistPathId, videoId: numericId))
            notify(Self.addedMessage)
            NotificationCenter.default.post(name: .peerTVPlaylistsNeedRefresh, object: nil)
            await refreshPlaylistMembership()
        } catch {
            notify("Could not add video to playlist")
        }
    }

    private func removeFromPlaylist(playlistPathId: String, elementId: Int, playlistId: Int) async {
        guard let apiClient else { return }
        do {
            _ = try await apiClient.rawRequest(.removePlaylistElement(playlistPathId: playlistPathId, elementId: elementId))
            playlistElementByPlaylistId.removeValue(forKey: playlistId)
            notify(Self.removedMessage)
            NotificationCenter.default.post(name: .peerTVPlaylistsNeedRefresh, object: nil)
        } catch {
            notify("Could not remove video from playlist")
        }
    }

    private func notify(_ message: String) {
        playlistMessage = message
        onFeedback?(Self.compactFeedback(for: message))
    }

    private static func compactFeedback(for message: String) -> String {
        switch message {
        case addedMessage: return "Added to playlist"
        case removedMessage: return "Removed from playlist"
        default: return message
        }
    }
}
