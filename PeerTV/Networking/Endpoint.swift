import Foundation

/// Type-safe endpoint definitions for the PeerTube REST API.
enum Endpoint {
    // Instance
    case config

    // OAuth
    case oauthClientsLocal
    case usersToken

    // Videos
    case videos(sort: String, start: Int, count: Int, includeAllPrivacy: Bool = false)
    case videoDetail(id: String)
    case videoFileToken(id: String)

    // Channels
    case videoChannels(start: Int, count: Int)
    case channelDetail(handle: String)
    case channelVideos(handle: String, start: Int, count: Int, sort: String, includeAllPrivacy: Bool = false)
    case channelPlaylists(handle: String, start: Int, count: Int)

    // Subscriptions (auth required)
    case mySubscriptions(start: Int, count: Int)
    case mySubscriptionVideos(start: Int, count: Int, sort: String)

    // History (auth required)
    case myHistory(start: Int, count: Int)

    // Playlists
    case videoPlaylists(start: Int, count: Int)
    case accountPlaylists(name: String, start: Int, count: Int)
    case playlistDetail(id: Int)
    case playlistVideos(id: Int, start: Int, count: Int)

    // User
    case usersMe

    // Ratings (auth required)
    case myVideoRating(videoId: Int)
    case rateVideo(id: Int, rating: String)

    // Playlist actions (auth required)
    case addVideoToPlaylist(playlistId: Int, videoId: Int)
    case removePlaylistElement(playlistId: Int, elementId: Int)
    case reorderPlaylistVideos(playlistId: Int, startPosition: Int, insertAfterPosition: Int, reorderLength: Int)

    // Subscription actions (auth required)
    case subscriptionExist(uri: String)
    case subscribe(uri: String)
    case unsubscribe(handle: String)

    // Watch history (auth required)
    case watchVideo(id: String, currentTime: Int)

    // Search
    case searchVideos(search: String, start: Int, count: Int)

    // Plugins
    case randomVideos

    var path: String {
        switch self {
        case .config:
            return "/api/v1/config"
        case .oauthClientsLocal:
            return "/api/v1/oauth-clients/local"
        case .usersToken:
            return "/api/v1/users/token"
        case .videos:
            return "/api/v1/videos"
        case .videoDetail(let id):
            return "/api/v1/videos/\(id)"
        case .videoFileToken(let id):
            return "/api/v1/videos/\(id)/token"
        case .videoChannels:
            return "/api/v1/video-channels"
        case .channelDetail(let handle):
            return "/api/v1/video-channels/\(handle)"
        case .channelVideos(let handle, _, _, _, _):
            return "/api/v1/video-channels/\(handle)/videos"
        case .channelPlaylists(let handle, _, _):
            return "/api/v1/video-channels/\(handle)/video-playlists"
        case .mySubscriptions:
            return "/api/v1/users/me/subscriptions"
        case .mySubscriptionVideos:
            return "/api/v1/users/me/subscriptions/videos"
        case .myHistory:
            return "/api/v1/users/me/history/videos"
        case .videoPlaylists:
            return "/api/v1/video-playlists"
        case .accountPlaylists(let name, _, _):
            return "/api/v1/accounts/\(name)/video-playlists"
        case .playlistDetail(let id):
            return "/api/v1/video-playlists/\(id)"
        case .playlistVideos(let id, _, _):
            return "/api/v1/video-playlists/\(id)/videos"
        case .usersMe:
            return "/api/v1/users/me"
        case .myVideoRating(let videoId):
            return "/api/v1/users/me/videos/\(videoId)/rating"
        case .rateVideo(let id, _):
            return "/api/v1/videos/\(id)/rate"
        case .addVideoToPlaylist(let playlistId, _):
            return "/api/v1/video-playlists/\(playlistId)/videos"
        case .removePlaylistElement(let playlistId, let elementId):
            return "/api/v1/video-playlists/\(playlistId)/videos/\(elementId)"
        case .reorderPlaylistVideos(let playlistId, _, _, _):
            return "/api/v1/video-playlists/\(playlistId)/videos/reorder"
        case .subscriptionExist:
            return "/api/v1/users/me/subscriptions/exist"
        case .subscribe:
            return "/api/v1/users/me/subscriptions"
        case .unsubscribe(let handle):
            return "/api/v1/users/me/subscriptions/\(handle)"
        case .watchVideo(let id, _):
            return "/api/v1/videos/\(id)/watching"
        case .searchVideos:
            return "/api/v1/search/videos"
        case .randomVideos:
            return "/plugins/random-video-tab/router/videos/random"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .videos(let sort, let start, let count, let includeAllPrivacy):
            var items = paging(start: start, count: count) + [URLQueryItem(name: "sort", value: sort)]
            if includeAllPrivacy { items.append(contentsOf: allPrivacyItems()) }
            return items
        case .videoChannels(let start, let count):
            return paging(start: start, count: count)
        case .channelVideos(_, let start, let count, let sort, let includeAllPrivacy):
            var items = paging(start: start, count: count) + [URLQueryItem(name: "sort", value: sort)]
            if includeAllPrivacy { items.append(contentsOf: allPrivacyItems()) }
            return items
        case .channelPlaylists(_, let start, let count):
            return paging(start: start, count: count)
        case .mySubscriptions(let start, let count):
            return paging(start: start, count: count)
        case .mySubscriptionVideos(let start, let count, let sort):
            return paging(start: start, count: count) + [URLQueryItem(name: "sort", value: sort)]
        case .myHistory(let start, let count):
            return paging(start: start, count: count)
        case .videoPlaylists(let start, let count):
            return paging(start: start, count: count)
        case .accountPlaylists(_, let start, let count):
            return paging(start: start, count: count)
        case .playlistVideos(_, let start, let count):
            return paging(start: start, count: count)
        case .searchVideos(let search, let start, let count):
            return paging(start: start, count: count)
                + [URLQueryItem(name: "search", value: search)]
                + allPrivacyItems()
        case .subscriptionExist(let uri):
            return [URLQueryItem(name: "uris", value: uri)]
        case .randomVideos:
            return [URLQueryItem(name: "count", value: "28")]
        default:
            return []
        }
    }

    var method: String {
        switch self {
        case .usersToken, .addVideoToPlaylist, .subscribe, .reorderPlaylistVideos,
             .videoFileToken:
            return "POST"
        case .rateVideo, .watchVideo:
            return "PUT"
        case .unsubscribe, .removePlaylistElement:
            return "DELETE"
        default:
            return "GET"
        }
    }

    var httpBody: Data? {
        switch self {
        case .rateVideo(_, let rating):
            return try? JSONSerialization.data(withJSONObject: ["rating": rating])
        case .addVideoToPlaylist(_, let videoId):
            return try? JSONSerialization.data(withJSONObject: ["videoId": videoId])
        case .reorderPlaylistVideos(_, let startPosition, let insertAfterPosition, let reorderLength):
            return try? JSONSerialization.data(withJSONObject: [
                "startPosition": startPosition,
                "insertAfterPosition": insertAfterPosition,
                "reorderLength": reorderLength
            ])
        case .subscribe(let uri):
            return try? JSONSerialization.data(withJSONObject: ["uri": uri])
        case .watchVideo(_, let currentTime):
            return try? JSONSerialization.data(withJSONObject: ["currentTime": currentTime])
        default:
            return nil
        }
    }

    var requiresAuth: Bool {
        switch self {
        case .mySubscriptions, .mySubscriptionVideos, .myHistory, .usersMe,
             .myVideoRating, .rateVideo, .addVideoToPlaylist,
             .removePlaylistElement, .reorderPlaylistVideos,
             .subscriptionExist, .subscribe, .unsubscribe,
             .watchVideo, .videoFileToken:
            return true
        default:
            return false
        }
    }

    private func paging(start: Int, count: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "count", value: "\(count)")
        ]
    }

    /// Privacy levels: 1=Public, 2=Unlisted, 3=Private, 4=Internal.
    /// include=1 adds non-published states (scheduled, draft).
    private func allPrivacyItems() -> [URLQueryItem] {
        [
            URLQueryItem(name: "privacyOneOf", value: "1"),
            URLQueryItem(name: "privacyOneOf", value: "2"),
            URLQueryItem(name: "privacyOneOf", value: "3"),
            URLQueryItem(name: "privacyOneOf", value: "4"),
            URLQueryItem(name: "include", value: "1"),
        ]
    }
}
