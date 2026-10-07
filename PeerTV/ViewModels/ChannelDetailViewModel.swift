import Foundation

@MainActor
final class ChannelDetailViewModel: ObservableObject {
    @Published var channel: VideoChannel?
    @Published var videos: [Video] = []
    @Published var playlists: [VideoPlaylist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let pageSize = 15
    private var videosStart = 0
    private var videosTotal: Int?
    private var apiClient: PeerTubeAPIClient?
    private var isAuthenticated = false
    private var canSeeAllVideos = false
    private var currentUsername: String?
    let handle: String

    var isOwnChannel: Bool {
        guard let currentUsername, let ownerName = channel?.ownerAccount?.name else { return false }
        return currentUsername == ownerName
    }

    private var includeAllPrivacyForListing: Bool {
        isOwnChannel && isAuthenticated && canSeeAllVideos
    }

    init(handle: String) {
        self.handle = handle
    }

    func configure(apiClient: PeerTubeAPIClient, isAuthenticated: Bool, canSeeAllVideos: Bool, currentUsername: String?) {
        self.apiClient = apiClient
        self.isAuthenticated = isAuthenticated
        self.canSeeAllVideos = canSeeAllVideos
        self.currentUsername = currentUsername
    }

    var canLoadMoreVideos: Bool {
        guard let videosTotal else { return true }
        return videosStart < videosTotal
    }

    func loadChannel() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            channel = try await apiClient.request(.channelDetail(handle: handle))
            async let vids: PaginatedResponse<Video> = apiClient.request(
                .channelVideos(handle: handle, start: 0, count: pageSize, sort: "-publishedAt", includeAllPrivacy: includeAllPrivacyForListing)
            )
            async let pls: PaginatedResponse<VideoPlaylist> = apiClient.request(
                .channelPlaylists(handle: handle, start: 0, count: pageSize)
            )
            let (videosResp, playlistsResp) = try await (vids, pls)
            videos = videosResp.items
            videosStart = videosResp.items.count
            videosTotal = videosResp.total
            playlists = playlistsResp.items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// First load only — avoids wiping scroll position when the view reappears (e.g. after closing the player).
    func loadInitialIfEmpty() async {
        guard channel == nil, videos.isEmpty else { return }
        await loadChannel()
    }

    func loadMoreVideos() async {
        guard let apiClient, !isLoading, canLoadMoreVideos else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let resp: PaginatedResponse<Video> = try await apiClient.request(
                .channelVideos(handle: handle, start: videosStart, count: pageSize, sort: "-publishedAt", includeAllPrivacy: includeAllPrivacyForListing)
            )
            let existingIds = Set(videos.map(\.stableId))
            let unique = resp.items.filter { !existingIds.contains($0.stableId) }
            videos.append(contentsOf: unique)
            videosStart += resp.items.count
            videosTotal = resp.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Subscription

/// Whether the signed-in user follows one channel, and the subscribe / unsubscribe toggle.
/// Shared by the channel page and the video page.
@MainActor
final class ChannelSubscriptionViewModel: ObservableObject {
    @Published private(set) var isSubscribed = false
    @Published private(set) var isToggling = false
    /// Set when subscribing or unsubscribing fails; views show it in an alert.
    @Published var error: String?

    private var apiClient: PeerTubeAPIClient?
    /// Channel handle (`name@host`), the form the subscription endpoints take.
    private var handle: String?

    func configure(apiClient: PeerTubeAPIClient, handle: String?) {
        self.apiClient = apiClient
        self.handle = handle
    }

    func check() async {
        guard let apiClient, let handle else { return }
        do {
            let data = try await apiClient.rawRequest(.subscriptionExist(uri: handle))
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
                isSubscribed = dict[handle] ?? false
            }
        } catch {
            isSubscribed = false
        }
    }

    func toggle() async {
        guard let apiClient, let handle, !isToggling else { return }
        isToggling = true
        defer { isToggling = false }

        let wasSubscribed = isSubscribed
        isSubscribed.toggle()

        do {
            if wasSubscribed {
                _ = try await apiClient.rawRequest(.unsubscribe(handle: handle))
            } else {
                _ = try await apiClient.rawRequest(.subscribe(uri: handle))
            }
        } catch {
            isSubscribed = wasSubscribed
            self.error = wasSubscribed
                ? "You couldn’t be unsubscribed from this channel. Try again later."
                : "You couldn’t be subscribed to this channel. Try again later."
        }
    }
}
