import Foundation

@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published var video: Video?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var rawJSON: String?

    @Published var userRating: String = "none"

    @Published var isDeleting = false
    @Published var deleteError: String?

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
    private var commentClient: PeerTubeAPIClient?
    private var commentsListClient: PeerTubeAPIClient?
    private var commentPostClients: [PeerTubeAPIClient] = []
    private var commentReadHost: String?
    private var accountName: String?
    let videoId: String
    let originHost: String?

    /// Client set in `configure`; used for playback from the detail screen.
    private(set) var configuredAPIClient: PeerTubeAPIClient?
    private(set) var canPostComments = false

    var usesFederatedOrigin: Bool {
        guard let originHost else { return false }
        return !originHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Host comments are fetched from (e.g. peertube.watch for federated trending); used for mirrored avatar URLs.
    var commentListHost: String? { commentReadHost }

    private var federatedAPIHosts: [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for raw in [commentReadHost, originHost] {
            let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            hosts.append(key)
        }
        return hosts
    }

    init(videoId: String, originHost: String? = nil) {
        self.videoId = videoId
        self.originHost = originHost
    }

    func configure(
        apiClient: PeerTubeAPIClient,
        commentClient: PeerTubeAPIClient? = nil,
        commentReadHost: String? = nil,
        additionalCommentClients: [PeerTubeAPIClient] = [],
        accountName: String?,
        canPostComments: Bool = false
    ) {
        self.apiClient = apiClient
        let postClient = commentClient ?? apiClient
        self.commentClient = postClient
        let readHost = Self.trimmedNonEmpty(commentReadHost)
        self.commentReadHost = readHost
        if let readHost {
            self.commentsListClient = PeerTubeOriginClients.publicClient(forHost: readHost)
        } else {
            self.commentsListClient = apiClient
        }
        self.configuredAPIClient = apiClient
        self.accountName = accountName
        self.canPostComments = canPostComments
        if usesFederatedOrigin, let firstRemote = additionalCommentClients.first {
            commentPostClients = uniqueCommentPostClients(
                primary: firstRemote,
                additional: [postClient] + Array(additionalCommentClients.dropFirst())
            )
        } else {
            commentPostClients = uniqueCommentPostClients(primary: postClient, additional: additionalCommentClients)
        }
    }

    func load() async {
        guard apiClient != nil || !federatedAPIHosts.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let data: Data
            if usesFederatedOrigin, !federatedAPIHosts.isEmpty {
                let (fetched, resolvedClient) = try await PeerTubeOriginClients.fetchVideoDetail(
                    videoId: videoId,
                    hosts: federatedAPIHosts
                )
                data = fetched
                apiClient = resolvedClient
                configuredAPIClient = resolvedClient
            } else if let apiClient {
                data = try await apiClient.rawRequest(.videoDetail(id: videoId))
            } else {
                return
            }
            if DebugFlags.showAPIExplorer {
                let json = try? JSONSerialization.jsonObject(with: data)
                let pretty = try? JSONSerialization.data(withJSONObject: json as Any, options: .prettyPrinted)
                rawJSON = pretty.flatMap { String(data: $0, encoding: .utf8) }
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            video = try decoder.decode(Video.self, from: data)
            await enrichChannelAvatarsIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Hot/federated rows and some origins omit channel avatars; fill from cache or API when needed.
    private func enrichChannelAvatarsIfNeeded() async {
        guard let current = video else { return }
        if let avatars = current.channel?.avatars, !avatars.isEmpty { return }

        if let avatars = PeerTubeOriginClients.cachedChannelAvatars(
            videoId: videoId,
            hosts: federatedAPIHosts
        ) {
            video = current.withChannelAvatars(avatars)
            return
        }

        for host in federatedAPIHosts {
            if let avatars = await PeerTubeOriginClients.fetchChannelAvatars(videoId: videoId, host: host) {
                video = current.withChannelAvatars(avatars)
                return
            }
        }

        if let client = apiClient, let handle = Self.channelHandle(for: current) {
            do {
                let channel: VideoChannel = try await client.request(.channelDetail(handle: handle))
                if let avatars = channel.avatars, !avatars.isEmpty {
                    video = current.withChannelAvatars(avatars)
                }
            } catch {}
        }
    }

    private static func channelHandle(for video: Video) -> String? {
        guard let name = video.channel?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        if let host = video.channel?.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return "\(name)@\(host)"
        }
        return name
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

    // MARK: - Delete

    /// Deletes the video using the given authenticated client (owner or admin on the home instance).
    /// Prefer the video's UUID so federation-stable ids resolve on the owner's host.
    @discardableResult
    func deleteVideo(using client: PeerTubeAPIClient, videoId: String) async -> Bool {
        let trimmed = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteError = "Missing video id."
            return false
        }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            _ = try await client.rawRequest(.deleteVideo(id: trimmed))
            return true
        } catch {
            deleteError = error.localizedDescription
            return false
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

    func loadComments(preservingExistingOnError: Bool = false) async {
        guard let commentsListClient else { return }
        commentsLoading = true
        commentsError = nil
        defer { commentsLoading = false }
        do {
            let response: VideoCommentsListResponse = try await commentsListClient.request(
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
            if !preservingExistingOnError {
                comments = []
                threadReplySupplements = []
            }
        }
    }

    private func fetchThreadReplyExtras(threadId: Int) async -> [VideoComment] {
        guard let commentsListClient else { return [] }
        do {
            let detail: VideoCommentThreadDetailResponse = try await commentsListClient.request(
                .videoCommentThreadDetail(videoId: videoId, threadId: threadId)
            )
            return flattenCommentBranches(detail.children)
        } catch {
            return []
        }
    }

    func postComment() async {
        guard !commentPostClients.isEmpty else { return }
        let trimmed = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isPostingComment = true
        commentPostError = nil
        defer { isPostingComment = false }

        var lastError: Error?
        if usesFederatedOrigin, let home = commentClient {
            await ensureVideoKnownOnInstance(home)
        }
        if await attemptPostComment(text: trimmed, lastError: &lastError) {
            return
        }
        // Remote import can finish shortly after search; one automatic retry before showing an error.
        if usesFederatedOrigin, let home = commentClient {
            await ensureVideoKnownOnInstance(home)
            if await attemptPostComment(text: trimmed, lastError: &lastError) {
                return
            }
        }

        if let apiError = lastError as? APIError, case APIError.httpError(404, _) = apiError {
            commentPostError = federatedCommentPostFailureMessage()
        } else {
            commentPostError = lastError?.localizedDescription ?? "Could not post comment."
        }
    }

    private func attemptPostComment(text: String, lastError: inout Error?) async -> Bool {
        for client in commentPostClients {
            do {
                let response: PostCommentResponse = try await client.request(
                    .postVideoComment(videoId: videoId, text: text)
                )
                commentDraft = ""
                if let posted = response.comment {
                    prependPostedComment(posted)
                }
                await loadComments(preservingExistingOnError: true)
                return true
            } catch {
                lastError = error
                if case APIError.httpError(404, _) = error {
                    continue
                }
                commentPostError = error.localizedDescription
                return true
            }
        }
        return false
    }

    private func prependPostedComment(_ comment: VideoComment) {
        guard comment.isDeleted != true else { return }
        guard !comments.contains(where: { $0.commentId != nil && $0.commentId == comment.commentId }) else { return }
        comments.insert(comment, at: 0)
    }

    private func uniqueCommentPostClients(
        primary: PeerTubeAPIClient,
        additional: [PeerTubeAPIClient]
    ) -> [PeerTubeAPIClient] {
        var seen = Set<String>()
        var clients: [PeerTubeAPIClient] = []
        func append(_ client: PeerTubeAPIClient) {
            guard let host = client.baseURL?.host?.lowercased(), seen.insert(host).inserted else { return }
            clients.append(client)
        }
        append(primary)
        for client in additional { append(client) }
        return clients
    }

    /// Watch URLs to import a remote video onto the user's instance (public index first, then media origin).
    private func federatedWatchURIs() -> [String] {
        var uris: [String] = []
        var seen = Set<String>()
        for host in [commentReadHost, originHost] {
            guard let h = Self.trimmedNonEmpty(host) else { continue }
            let uri = "https://\(h)/videos/watch/\(videoId)"
            guard seen.insert(uri).inserted else { continue }
            uris.append(uri)
        }
        return uris
    }

    /// Imports a remote video into the user's instance via `GET /search/videos` when it is not in the local DB yet.
    private func ensureVideoKnownOnInstance(_ client: PeerTubeAPIClient) async {
        guard usesFederatedOrigin else { return }
        if await videoExistsOnInstance(client) { return }

        for uri in federatedWatchURIs() {
            do {
                let _: PaginatedResponse<Video> = try await client.request(
                    .searchVideos(search: uri, start: 0, count: 1, scope: .instance)
                )
            } catch {
                continue
            }
            if await waitForVideoOnInstance(client) { return }
        }
    }

    private func videoExistsOnInstance(_ client: PeerTubeAPIClient) async -> Bool {
        do {
            let _: Video = try await client.request(.videoDetail(id: videoId))
            return true
        } catch {
            if case APIError.httpError(404, _) = error { return false }
            return false
        }
    }

    /// After remote URI search, the instance may need a moment before `GET /videos/{id}` succeeds.
    private func waitForVideoOnInstance(_ client: PeerTubeAPIClient) async -> Bool {
        let delaysNanoseconds: [UInt64] = [0, 300_000_000, 600_000_000, 1_000_000_000, 1_500_000_000]
        for delay in delaysNanoseconds {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            if await videoExistsOnInstance(client) { return true }
        }
        return false
    }

    private func federatedCommentPostFailureMessage() -> String {
        var hosts: [String] = []
        if let read = commentReadHost { hosts.append(read) }
        if let origin = Self.trimmedNonEmpty(originHost),
           !hosts.contains(where: { $0.caseInsensitiveCompare(origin) == .orderedSame }) {
            hosts.append(origin)
        }
        if hosts.isEmpty {
            return "Your server doesn't know this video yet, so comments can't be posted from here."
        }
        let hostList = hosts.joined(separator: " or ")
        return "Your server doesn't have this video yet. Sign in to \(hostList) in Settings to comment, or ask your admin to enable remote search."
    }

    private static func trimmedNonEmpty(_ string: String?) -> String? {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func toggleCommentSelection(_ id: String) {
        if selectedCommentId == id {
            selectedCommentId = nil
        } else {
            selectedCommentId = id
        }
    }
}
