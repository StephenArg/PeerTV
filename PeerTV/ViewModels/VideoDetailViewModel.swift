import Foundation

@MainActor
final class VideoDetailViewModel: ObservableObject {
    /// Shown after a successful add; used by the detail view for toast styling.
    static let playlistAddedSuccessMessage = "Video added to playlist"

    @Published var video: Video?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var rawJSON: String?

    @Published var userRating: String = "none"
    @Published var myPlaylists: [VideoPlaylist] = []
    @Published var myPlaylistsLoaded = false
    @Published var playlistMessage: String?

    @Published var comments: [VideoComment] = []
    /// Replies loaded per thread via `GET …/comment-threads/{threadId}` (list often omits them).
    @Published private(set) var threadReplySupplements: [VideoComment] = []
    @Published var commentsLoading = false
    @Published var commentsError: String?
    @Published var commentDraft = ""
    @Published var isPostingComment = false
    @Published var commentPostError: String?
    @Published var selectedCommentId: String?

    private var apiClient: PeerTubeAPIClient?
    private var accountName: String?
    let videoId: String
    let originHost: String?

    /// Client set in `configure`; used for playback from the detail screen.
    private(set) var configuredAPIClient: PeerTubeAPIClient?

    var usesFederatedOrigin: Bool {
        guard let originHost else { return false }
        return !originHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(videoId: String, originHost: String? = nil) {
        self.videoId = videoId
        self.originHost = originHost
    }

    func configure(apiClient: PeerTubeAPIClient, accountName: String?) {
        self.apiClient = apiClient
        self.configuredAPIClient = apiClient
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
        myPlaylistsLoaded = false
        defer { myPlaylistsLoaded = true }
        guard let apiClient, let name = accountName else {
            myPlaylists = []
            return
        }
        do {
            let response: PaginatedResponse<VideoPlaylist> = try await apiClient.request(
                .accountPlaylists(name: name, start: 0, count: 100)
            )
            myPlaylists = response.data ?? []
        } catch {
            myPlaylists = []
        }
    }

    /// Creates a private playlist then adds the current video.
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
            playlistMessage = message
            return .failure(error)
        }
    }

    func addToPlaylist(playlistPathId: String) async {
        guard let apiClient, let numericId = video?.id else { return }
        do {
            _ = try await apiClient.rawRequest(.addVideoToPlaylist(playlistPathId: playlistPathId, videoId: numericId))
            playlistMessage = Self.playlistAddedSuccessMessage
            NotificationCenter.default.post(name: .peerTVPlaylistsNeedRefresh, object: nil)
        } catch {
            playlistMessage = "Could not add video to playlist"
        }
    }

    // MARK: - Comments

    private var mergedComments: [VideoComment] {
        var byId: [Int: VideoComment] = [:]
        for c in comments {
            if let id = c.commentId { byId[id] = c }
        }
        for c in threadReplySupplements {
            if let id = c.commentId { byId[id] = c }
        }
        return Array(byId.values)
    }

    /// Roots first (newest first), then nested replies in thread order.
    var commentDisplayRows: [CommentDisplayRow] {
        CommentDisplayRow.rows(from: mergedComments)
    }

    func loadComments() async {
        guard let apiClient else { return }
        commentsLoading = true
        commentsError = nil
        defer { commentsLoading = false }
        do {
            let response: VideoCommentsListResponse = try await apiClient.request(
                .videoCommentThreads(videoId: videoId, start: 0, count: 100, sort: "-createdAt")
            )
            selectedCommentId = nil
            comments = response.data ?? []
            threadReplySupplements = []

            let roots = comments.filter { $0.isDeleted != true && $0.isRoot }
            let extras = await withTaskGroup(of: [VideoComment].self) { group -> [VideoComment] in
                for root in roots {
                    guard let tid = root.commentId else { continue }
                    group.addTask {
                        await self.fetchThreadReplyExtras(threadId: tid)
                    }
                }
                var merged: [VideoComment] = []
                for await batch in group {
                    merged.append(contentsOf: batch)
                }
                return merged
            }
            threadReplySupplements = extras
        } catch {
            commentsError = error.localizedDescription
            comments = []
            threadReplySupplements = []
        }
    }

    private func fetchThreadReplyExtras(threadId: Int) async -> [VideoComment] {
        guard let apiClient else { return [] }
        do {
            let detail: VideoCommentThreadDetailResponse = try await apiClient.request(
                .videoCommentThreadDetail(videoId: videoId, threadId: threadId)
            )
            return flattenCommentBranches(detail.children)
        } catch {
            return []
        }
    }

    func postComment() async {
        guard let apiClient else { return }
        let trimmed = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isPostingComment = true
        commentPostError = nil
        defer { isPostingComment = false }
        do {
            let _: PostCommentResponse = try await apiClient.request(
                .postVideoComment(videoId: videoId, text: trimmed)
            )
            commentDraft = ""
            await loadComments()
        } catch {
            commentPostError = error.localizedDescription
        }
    }

    func toggleCommentSelection(_ id: String) {
        if selectedCommentId == id {
            selectedCommentId = nil
        } else {
            selectedCommentId = id
        }
    }
}
