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

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: VideoPlaylist, rhs: VideoPlaylist) -> Bool { lhs.id == rhs.id }
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
}
