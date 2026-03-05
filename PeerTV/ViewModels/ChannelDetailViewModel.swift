import Foundation

@MainActor
final class ChannelDetailViewModel: ObservableObject {
    @Published var channel: VideoChannel?
    @Published var videos: [Video] = []
    @Published var playlists: [VideoPlaylist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var isSubscribed = false
    @Published var isTogglingSubscription = false

    private let pageSize = 15
    private var videosStart = 0
    private var videosTotal: Int?
    private var apiClient: PeerTubeAPIClient?
    private var isAuthenticated = false
    private var currentUsername: String?
    let handle: String

    var isOwnChannel: Bool {
        guard let currentUsername, let ownerName = channel?.ownerAccount?.name else { return false }
        return currentUsername == ownerName
    }

    init(handle: String) {
        self.handle = handle
    }

    func configure(apiClient: PeerTubeAPIClient, isAuthenticated: Bool, currentUsername: String?) {
        self.apiClient = apiClient
        self.isAuthenticated = isAuthenticated
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
                .channelVideos(handle: handle, start: 0, count: pageSize, sort: "-publishedAt", includeAllPrivacy: isAuthenticated)
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

    func loadMoreVideos() async {
        guard let apiClient, !isLoading, canLoadMoreVideos else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let resp: PaginatedResponse<Video> = try await apiClient.request(
                .channelVideos(handle: handle, start: videosStart, count: pageSize, sort: "-publishedAt", includeAllPrivacy: isAuthenticated)
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

    // MARK: - Subscription

    func checkSubscription() async {
        guard let apiClient, isAuthenticated else { return }
        do {
            let data = try await apiClient.rawRequest(.subscriptionExist(uri: handle))
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
                isSubscribed = dict[handle] ?? false
            }
        } catch {
            isSubscribed = false
        }
    }

    func toggleSubscription() async {
        guard let apiClient, !isTogglingSubscription else { return }
        isTogglingSubscription = true
        defer { isTogglingSubscription = false }

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
        }
    }
}
