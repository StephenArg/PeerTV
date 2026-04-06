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

    /// Include fields that affect list tiles and navigation labels. Using only `id` made SwiftUI treat
    /// refetched playlists as unchanged, so `videosLength` and thumbnails never updated on screen.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(videosLength)
        hasher.combine(thumbnailPath)
        hasher.combine(displayName)
        hasher.combine(updatedAt)
    }

    static func == (lhs: VideoPlaylist, rhs: VideoPlaylist) -> Bool {
        lhs.id == rhs.id
            && lhs.videosLength == rhs.videosLength
            && lhs.thumbnailPath == rhs.thumbnailPath
            && lhs.displayName == rhs.displayName
            && lhs.updatedAt == rhs.updatedAt
    }
}

struct PlaylistPrivacy: Decodable {
    let id: Int?
    let label: String?
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
