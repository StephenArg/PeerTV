import Foundation

struct RandomVideo: Decodable, Identifiable, Hashable {
    let uuid: String?
    let name: String?
    let nsfw: Bool?
    let duration: Int?
    let views: Int?
    let publishedAt: String?
    let thumbnailFile: String?
    let thumbnailPath: String?
    let channelName: String?
    let instanceHost: String?
    let ownerAvatarUrl: String?

    var id: String { uuid ?? UUID().uuidString }

    /// Remote: full `thumbnailPath` URL. Local: `null` → `/lazy-static/thumbnails/{thumbnailFile}`.
    private var resolvedThumbnailPath: String? {
        if let p = thumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return p
        }
        if let f = thumbnailFile?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
            return "/lazy-static/thumbnails/\(f)"
        }
        return nil
    }

    /// Absolute avatar URL for tiles; relative paths use local instance or `instanceHost` (federated).
    private func resolvedOwnerAvatarAbsoluteString(instanceURL: URL?) -> String? {
        guard let url = PeerTubeAssetURL.resolve(
            path: ownerAvatarUrl,
            instanceBase: instanceURL,
            federatedHost: instanceHost
        ) else { return nil }
        return url.absoluteString
    }

    func toVideo(instanceURL: URL?) -> Video {
        let avatarPath = resolvedOwnerAvatarAbsoluteString(instanceURL: instanceURL)
        let channelAvatars: [ActorImage]? = avatarPath.map {
            [ActorImage(width: nil, path: $0, createdAt: nil, updatedAt: nil)]
        }

        return Video(
            id: nil,
            uuid: uuid,
            name: name,
            description: nil,
            duration: duration,
            views: views,
            likes: nil,
            dislikes: nil,
            createdAt: nil,
            publishedAt: publishedAt,
            thumbnailPath: resolvedThumbnailPath,
            previewPath: nil,
            embedPath: nil,
            channel: VideoChannelSummary(
                id: nil,
                name: channelName,
                displayName: channelName,
                url: nil,
                host: instanceHost,
                avatars: channelAvatars
            ),
            account: nil,
            privacy: nil,
            streamingPlaylists: nil,
            files: nil
        )
    }
}
