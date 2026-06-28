import Foundation

struct VideoPlaylist: Decodable, Identifiable, Hashable {
    let id: Int?
    let uuid: String?
    let displayName: String?
    let description: String?
    let privacy: PlaylistPrivacy?
    let thumbnailPath: String?
    let videosLength: Int?
    let createdAt: String?
    let updatedAt: String?
    let ownerAccount: AccountSummary?
    let videoChannel: VideoChannelSummary?

    /// Path segment for `GET/PUT/… /api/v1/video-playlists/{id}`. PeerTube often returns **404** for non-public playlists when using the numeric id; the **UUID** works for unlisted/private when you are allowed to view the playlist.
    var peertubePlaylistPathId: String? {
        if let u = uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            return u
        }
        if let id { return "\(id)" }
        return nil
    }

    /// Include fields that affect list tiles and navigation labels. Using only `id` made SwiftUI treat
    /// refetched playlists as unchanged, so `videosLength` and thumbnails never updated on screen.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(videosLength)
        hasher.combine(thumbnailPath)
        hasher.combine(displayName)
        hasher.combine(updatedAt)
        hasher.combine(privacy?.id)
    }

    static func == (lhs: VideoPlaylist, rhs: VideoPlaylist) -> Bool {
        lhs.id == rhs.id
            && lhs.videosLength == rhs.videosLength
            && lhs.thumbnailPath == rhs.thumbnailPath
            && lhs.displayName == rhs.displayName
            && lhs.updatedAt == rhs.updatedAt
            && lhs.privacy?.id == rhs.privacy?.id
    }
}

struct PlaylistPrivacy: Decodable {
    let id: Int?
    let label: String?
}

/// Row for the playlist privacy picker (`GET /api/v1/video-playlists/privacies` → `{"1":"Public",…}`).
struct VideoPlaylistPrivacyMenuItem: Identifiable, Hashable {
    let id: Int
    let label: String
}

/// One row from `GET /api/v1/users/me/video-playlists/videos-exist` (video id → playlist memberships).
struct VideoPlaylistExistEntry: Decodable {
    let playlistElementId: Int?
    let playlistId: Int?
    let startTimestamp: Int?
    let stopTimestamp: Int?
}

struct PlaylistElement: Decodable, Identifiable {
    let id: Int?
    let position: Int?
    let startTimestamp: Int?
    let stopTimestamp: Int?
    let video: Video?

    /// Stable key for `ForEach` when `id` may be missing.
    var stableRowID: String {
        if let id { return "pl:\(id)" }
        if let sid = video?.stableId { return "pv:\(sid)" }
        return "p:unknown"
    }
}
