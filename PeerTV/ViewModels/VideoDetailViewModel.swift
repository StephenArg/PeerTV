import Foundation

@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published var video: Video?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var rawJSON: String?

    @Published var userRating: String = "none"
    @Published var myPlaylists: [VideoPlaylist] = []
    @Published var playlistMessage: String?

    private var apiClient: PeerTubeAPIClient?
    private var accountName: String?
    let videoId: String

    init(videoId: String) {
        self.videoId = videoId
    }

    func configure(apiClient: PeerTubeAPIClient, accountName: String?) {
        self.apiClient = apiClient
        self.accountName = accountName
    }

    func load() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let data = try await apiClient.rawRequest(.videoDetail(id: videoId))
            if DebugFlags.showAPIExplorer {
                let json = try? JSONSerialization.jsonObject(with: data)
                let pretty = try? JSONSerialization.data(withJSONObject: json as Any, options: .prettyPrinted)
                rawJSON = pretty.flatMap { String(data: $0, encoding: .utf8) }
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            video = try decoder.decode(Video.self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Rating

    func loadUserRating() async {
        guard let apiClient, let numericId = video?.id else { return }
        do {
            let rating: UserVideoRating = try await apiClient.request(.myVideoRating(videoId: numericId))
            userRating = rating.rating ?? "none"
        } catch {
            userRating = "none"
        }
    }

    func toggleLike() async {
        let newRating = userRating == "like" ? "none" : "like"
        await rate(newRating)
    }

    func toggleDislike() async {
        let newRating = userRating == "dislike" ? "none" : "dislike"
        await rate(newRating)
    }

    private func rate(_ rating: String) async {
        guard let apiClient, let numericId = video?.id else { return }

        let oldRating = userRating
        let oldLikes = video?.likes
        let oldDislikes = video?.dislikes

        userRating = rating
        adjustCounts(from: oldRating, to: rating)

        do {
            _ = try await apiClient.rawRequest(.rateVideo(id: numericId, rating: rating))
        } catch {
            userRating = oldRating
            video?.likes = oldLikes
            video?.dislikes = oldDislikes
        }
    }

    private func adjustCounts(from old: String, to new: String) {
        if old == "like" { video?.likes = (video?.likes ?? 1) - 1 }
        if old == "dislike" { video?.dislikes = (video?.dislikes ?? 1) - 1 }
        if new == "like" { video?.likes = (video?.likes ?? 0) + 1 }
        if new == "dislike" { video?.dislikes = (video?.dislikes ?? 0) + 1 }
    }

    // MARK: - Playlists

    func loadMyPlaylists() async {
        guard let apiClient, let name = accountName else { return }
        do {
            let response: PaginatedResponse<VideoPlaylist> = try await apiClient.request(
                .accountPlaylists(name: name, start: 0, count: 100)
            )
            myPlaylists = response.data ?? []
        } catch {
            myPlaylists = []
        }
    }

    func addToPlaylist(_ playlistId: Int) async {
        guard let apiClient, let numericId = video?.id else { return }
        do {
            _ = try await apiClient.rawRequest(.addVideoToPlaylist(playlistId: playlistId, videoId: numericId))
            playlistMessage = "Added to playlist"
            NotificationCenter.default.post(name: .peerTVPlaylistsNeedRefresh, object: nil)
        } catch {
            playlistMessage = "Failed to add to playlist"
        }
    }
}
