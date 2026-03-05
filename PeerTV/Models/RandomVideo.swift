import Foundation

struct RandomVideo: Decodable, Identifiable, Hashable {
    let uuid: String?
    let name: String?
    let nsfw: Bool?
    let thumbnailFile: String?
    let thumbnailPath: String?
    let channelName: String?
    let instanceHost: String?

    var id: String { uuid ?? UUID().uuidString }

    func toVideo() -> Video {
        Video(
            id: nil,
            uuid: uuid,
            name: name,
            description: nil,
            duration: nil,
            views: nil,
            likes: nil,
            dislikes: nil,
            createdAt: nil,
            publishedAt: nil,
            thumbnailPath: thumbnailPath,
            previewPath: nil,
            embedPath: nil,
            channel: VideoChannelSummary(
                id: nil,
                name: channelName,
                displayName: channelName,
                url: nil,
                host: instanceHost,
                avatars: nil
            ),
            account: nil,
            privacy: nil,
            streamingPlaylists: nil,
            files: nil
        )
    }
}
