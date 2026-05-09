import Foundation

/// Response from `POST /api/v1/video-playlists` (multipart).
struct CreateVideoPlaylistResponse: Decodable {
    let videoPlaylist: CreateVideoPlaylistPayload
}

struct CreateVideoPlaylistPayload: Decodable {
    let id: Int
}
