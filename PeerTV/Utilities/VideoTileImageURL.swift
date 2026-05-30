import Foundation

/// Resolves the same thumbnail/avatar URLs shown on `VideoCardView` tiles (for history capture).
@MainActor
enum VideoTileImageURL {
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
        return PeerTubeAssetURL.resolve(
            avatars: video.channel?.avatars ?? video.account?.avatars,
            instanceBase: session.baseURL,
            federatedHost: federatedDisplay ? video.commentReadHost : nil,
            cacheHost: federatedDisplay ? video.originHost : nil
        )
    }
}
