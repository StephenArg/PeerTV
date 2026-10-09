import Foundation

/// Which search backend query parameters to use (`GET /api/v1/search/videos`).
enum SearchVideosScope {
    /// Connected instance (broad privacy filters when logged in).
    case instance
    /// SepiaSearch public federation (`sort=-match`, no privacy widening).
    case global
}

/// Type-safe endpoint definitions for the PeerTube REST API.
enum Endpoint {
    // Instance
    case config

    // OAuth
    case oauthClientsLocal
    case usersToken

    // Videos
    case videos(sort: String, start: Int, count: Int, includeAllPrivacy: Bool = false, isLocal: Bool? = nil, categoryIds: [Int] = [], languageIds: [String] = [], isLive: Bool? = nil)
    case videoCategories
    case videoLanguages
    case videoDetail(id: String)
    case deleteVideo(id: String)
    case videoFileToken(id: String)
    case videoStoryboards(id: String)
    case videoCaptions(id: String)
    case videoChapters(id: String)
    case videoCommentThreads(videoId: String, start: Int, count: Int, sort: String)
    case videoCommentThreadDetail(videoId: String, threadId: Int)
    case postVideoComment(videoId: String, text: String)

    // Channels
    case videoChannels(start: Int, count: Int, sort: String = "-createdAt")
    /// Channel search. Without `search`, lists the channels of `host` (used for "this server only");
    /// that route only sorts by `-createdAt` (or `-match` with a term).
    case searchVideoChannels(search: String?, host: String?, start: Int, count: Int, sort: String)
    case channelDetail(handle: String)
    case channelVideos(handle: String, start: Int, count: Int, sort: String, includeAllPrivacy: Bool = false)
    case channelPlaylists(handle: String, start: Int, count: Int)

    // Subscriptions (auth required)
    case mySubscriptions(start: Int, count: Int)
    case mySubscriptionVideos(start: Int, count: Int, sort: String)

    // History (auth required)
    case myHistory(start: Int, count: Int)
    /// Numeric `Video.id`; the history routes don't accept UUIDs.
    case removeHistoryVideo(videoId: Int)
    case clearHistory

    // Playlists
    case videoPlaylists(start: Int, count: Int)
    case videoPlaylistPrivacies
    case accountPlaylists(name: String, start: Int, count: Int)
    case accountVideoChannels(name: String, start: Int, count: Int)
    case playlistDetail(playlistPathId: String)
    case playlistVideos(playlistPathId: String, start: Int, count: Int)
    case videosExistInPlaylists(videoIds: [Int])

    // User
    case usersMe

    // Ratings (auth required)
    case myVideoRating(videoId: Int)
    case rateVideo(id: Int, rating: String)

    // Playlist actions (auth required)
    case addVideoToPlaylist(playlistPathId: String, videoId: Int)
    case removePlaylistElement(playlistPathId: String, elementId: Int)
    case reorderPlaylistVideos(playlistPathId: String, startPosition: Int, insertAfterPosition: Int, reorderLength: Int)
    case deletePlaylist(playlistPathId: String)

    // Subscription actions (auth required)
    case subscriptionExist(uri: String)
    case subscribe(uri: String)
    case unsubscribe(handle: String)

    // Watch progress: counts the view and, when signed in, saves the time for history and resume
    case watchVideo(id: String, currentTime: Int)

    // Search
    case searchVideos(search: String, start: Int, count: Int, scope: SearchVideosScope = .instance, includeAllPrivacy: Bool = false)

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
        case .videoCategories:
            return "/api/v1/videos/categories"
        case .videoLanguages:
            return "/api/v1/videos/languages"
        case .videoDetail(let id), .deleteVideo(let id):
            return "/api/v1/videos/\(id)"
        case .videoFileToken(let id):
            return "/api/v1/videos/\(id)/token"
        case .videoStoryboards(let id):
            return "/api/v1/videos/\(id)/storyboards"
        case .videoCaptions(let id):
            return "/api/v1/videos/\(id)/captions"
        case .videoChapters(let id):
            return "/api/v1/videos/\(id)/chapters"
        case .videoCommentThreads(let id, _, _, _), .postVideoComment(let id, _):
            return "/api/v1/videos/\(id)/comment-threads"
        case .videoCommentThreadDetail(let id, let threadId):
            return "/api/v1/videos/\(id)/comment-threads/\(threadId)"
        case .videoChannels:
            return "/api/v1/video-channels"
        case .searchVideoChannels:
            return "/api/v1/search/video-channels"
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
        case .removeHistoryVideo(let videoId):
            return "/api/v1/users/me/history/videos/\(videoId)"
        case .clearHistory:
            return "/api/v1/users/me/history/videos/remove"
        case .videoPlaylists:
            return "/api/v1/video-playlists"
        case .videoPlaylistPrivacies:
            return "/api/v1/video-playlists/privacies"
        case .accountPlaylists(let name, _, _):
            return "/api/v1/accounts/\(name)/video-playlists"
        case .accountVideoChannels(let name, _, _):
            return "/api/v1/accounts/\(name)/video-channels"
        case .playlistDetail(let playlistPathId):
            return "/api/v1/video-playlists/\(playlistPathId)"
        case .playlistVideos(let playlistPathId, _, _):
            return "/api/v1/video-playlists/\(playlistPathId)/videos"
        case .videosExistInPlaylists:
            return "/api/v1/users/me/video-playlists/videos-exist"
        case .usersMe:
            return "/api/v1/users/me"
        case .myVideoRating(let videoId):
            return "/api/v1/users/me/videos/\(videoId)/rating"
        case .rateVideo(let id, _):
            return "/api/v1/videos/\(id)/rate"
        case .addVideoToPlaylist(let playlistPathId, _):
            return "/api/v1/video-playlists/\(playlistPathId)/videos"
        case .removePlaylistElement(let playlistPathId, let elementId):
            return "/api/v1/video-playlists/\(playlistPathId)/videos/\(elementId)"
        case .reorderPlaylistVideos(let playlistPathId, _, _, _):
            return "/api/v1/video-playlists/\(playlistPathId)/videos/reorder"
        case .deletePlaylist(let playlistPathId):
            return "/api/v1/video-playlists/\(playlistPathId)"
        case .subscriptionExist:
            return "/api/v1/users/me/subscriptions/exist"
        case .subscribe:
            return "/api/v1/users/me/subscriptions"
        case .unsubscribe(let handle):
            return "/api/v1/users/me/subscriptions/\(handle)"
        case .watchVideo(let id, _):
            // The documented route; `/watching` was the older name and is no longer in the API reference.
            return "/api/v1/videos/\(id)/views"
        case .searchVideos:
            return "/api/v1/search/videos"
        case .randomVideos:
            return "/plugins/random-video-tab/router/videos/random"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .videos(let sort, let start, let count, let includeAllPrivacy, let isLocal, let categoryIds, let languageIds, let isLive):
            var items = paging(start: start, count: count) + [URLQueryItem(name: "sort", value: sort)]
            if includeAllPrivacy { items.append(contentsOf: allPrivacyItems()) }
            if let isLocal { items.append(URLQueryItem(name: "isLocal", value: isLocal ? "true" : "false")) }
            for id in categoryIds {
                items.append(URLQueryItem(name: "categoryOneOf", value: "\(id)"))
            }
            for id in languageIds {
                items.append(URLQueryItem(name: "languageOneOf", value: id))
            }
            if let isLive { items.append(URLQueryItem(name: "isLive", value: isLive ? "true" : "false")) }
            return items
        case .videoChannels(let start, let count, let sort):
            return paging(start: start, count: count) + [URLQueryItem(name: "sort", value: sort)]
        case .searchVideoChannels(let search, let host, let start, let count, let sort):
            var items = paging(start: start, count: count) + [URLQueryItem(name: "sort", value: sort)]
            if let search, !search.isEmpty { items.append(URLQueryItem(name: "search", value: search)) }
            if let host, !host.isEmpty { items.append(URLQueryItem(name: "host", value: host)) }
            return items
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
        case .accountVideoChannels(_, let start, let count):
            return paging(start: start, count: count)
        case .playlistVideos(_, let start, let count):
            return paging(start: start, count: count)
        case .searchVideos(let search, let start, let count, let scope, let includeAllPrivacy):
            var items = paging(start: start, count: count)
                + [URLQueryItem(name: "search", value: search)]
            switch scope {
            case .instance:
                if includeAllPrivacy { items.append(contentsOf: allPrivacyItems()) }
            case .global:
                items.append(URLQueryItem(name: "sort", value: "-match"))
                items.append(URLQueryItem(name: "nsfw", value: "false"))
            }
            return items
        case .subscriptionExist(let uri):
            return [URLQueryItem(name: "uris", value: uri)]
        case .videosExistInPlaylists(let videoIds):
            return videoIds.map { URLQueryItem(name: "videoIds", value: "\($0)") }
        case .randomVideos:
            return [URLQueryItem(name: "count", value: "28")]
        case .videoCommentThreads(_, let start, let count, let sort):
            return paging(start: start, count: count) + [URLQueryItem(name: "sort", value: sort)]
        default:
            return []
        }
    }

    var method: String {
        switch self {
        case .usersToken, .addVideoToPlaylist, .subscribe, .reorderPlaylistVideos,
             .videoFileToken, .postVideoComment, .clearHistory, .watchVideo:
            return "POST"
        case .rateVideo:
            return "PUT"
        case .unsubscribe, .removePlaylistElement, .deletePlaylist, .deleteVideo, .removeHistoryVideo:
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
        case .postVideoComment(_, let text):
            return try? JSONSerialization.data(withJSONObject: ["text": text])
        case .clearHistory:
            // Optional `beforeDate`; an empty object clears everything.
            return try? JSONSerialization.data(withJSONObject: [String: Any]())
        default:
            return nil
        }
    }

    var requiresAuth: Bool {
        switch self {
        case .mySubscriptions, .mySubscriptionVideos, .myHistory, .removeHistoryVideo, .clearHistory, .usersMe,
             .myVideoRating, .rateVideo, .addVideoToPlaylist,
             .removePlaylistElement, .reorderPlaylistVideos, .deletePlaylist,
             .deleteVideo,
             .videosExistInPlaylists,
             .subscriptionExist, .subscribe, .unsubscribe,
             .videoFileToken, .postVideoComment:
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

// MARK: - Diagnostics (no secrets)

extension Endpoint {
    /// Short label for Unified Logging (paths + non-sensitive parameters only).
    var networkLogDescription: String {
        switch self {
        case .videos(let sort, let start, let count, let includeAllPrivacy, let isLocal, let categoryIds, let languageIds, let isLive):
            let scope = isLocal.map { $0 ? "local" : "remote" } ?? "all"
            let live = isLive.map { $0 ? "live" : "recorded" } ?? "any"
            return "GET /api/v1/videos sort=\(sort) start=\(start) count=\(count) includeAllPrivacy=\(includeAllPrivacy) scope=\(scope) categories=\(categoryIds.count) languages=\(languageIds.count) live=\(live)"
        case .channelVideos(let handle, let start, let count, let sort, let includeAllPrivacy):
            return "GET …/video-channels/\(handle)/videos sort=\(sort) start=\(start) count=\(count) includeAllPrivacy=\(includeAllPrivacy)"
        case .searchVideos(let search, let start, let count, let scope, let includeAllPrivacy):
            let q = String(search.prefix(64))
            let scopeLabel = scope == .global ? "global" : "instance"
            return "GET /api/v1/search/videos q=\(q) start=\(start) count=\(count) scope=\(scopeLabel) includeAllPrivacy=\(includeAllPrivacy)"
        case .searchVideoChannels(let search, let host, let start, let count, let sort):
            let q = String((search ?? "").prefix(64))
            return "GET /api/v1/search/video-channels q=\(q) host=\(host ?? "any") sort=\(sort) start=\(start) count=\(count)"
        case .subscriptionExist(let uri):
            return "GET …/subscriptions/exist uri=\(String(uri.prefix(120)))"
        case .subscribe(let uri):
            return "POST …/subscriptions uri=\(String(uri.prefix(120)))"
        default:
            return "\(method) \(path)"
        }
    }
}
