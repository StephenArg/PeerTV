import Foundation

/// Resolves the same thumbnail/avatar URLs shown on `VideoCardView` tiles (for history capture).
@MainActor
enum VideoTileImageURL {
    /// Tiles render the channel avatar at 44pt; 120px covers Retina scaling without
    /// pulling the multi-hundred-pixel source avatars some instances expose.
    private static let tileAvatarPreferredWidth = 120

    static func thumbnail(
        for video: Video,
        session: SessionStore,
        federatedDisplay: Bool,
        override: URL? = nil
    ) -> URL? {
        if let override { return override }
        if federatedDisplay {
            return PeerTubeAssetURL.resolve(
                path: video.thumbnailPath,
                instanceBase: session.baseURL,
                federatedHost: video.commentReadHost,
                cacheHost: video.originHost
            )
        }
        return session.thumbnailURL(path: video.thumbnailPath)
    }

    static func channelAvatar(
        for video: Video,
        session: SessionStore,
        federatedDisplay: Bool,
        override: URL? = nil
    ) -> URL? {
        if let override { return override }
        // Fediverse-trending rows enrich avatars from the index host (`commentReadHost`,
        // e.g. peertube.watch), so the avatar's path/fileUrl is only valid there — resolve
        // against it. SepiaSearch results have no index host and stay on the media origin.
        let avatarCacheHost = federatedDisplay ? (video.commentReadHost ?? video.originHost) : nil
        return PeerTubeAssetURL.resolve(
            avatars: video.channel?.avatars ?? video.account?.avatars,
            instanceBase: session.baseURL,
            federatedHost: federatedDisplay ? video.commentReadHost : nil,
            cacheHost: avatarCacheHost,
            preferredWidth: tileAvatarPreferredWidth
        )
    }
}
