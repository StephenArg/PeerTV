import Foundation

/// Shared unauthenticated API clients for federated / SepiaSearch origins.
@MainActor
enum PeerTubeOriginClients {
    static let sepiaSearchBaseURL = URL(string: "https://sepiasearch.org/")!

    private static let anonymousTokenStore = TokenStore(accountId: TokenStore.preLoginAccountId)

    private static let sepiaSearchClient: PeerTubeAPIClient = {
        let client = PeerTubeAPIClient(tokenStore: anonymousTokenStore)
        client.baseURL = sepiaSearchBaseURL
        return client
    }()

    private static var hostClients: [String: PeerTubeAPIClient] = [:]

    static var sepiaSearch: PeerTubeAPIClient { sepiaSearchClient }

    /// Public PeerTube API client for a remote instance hostname.
    static func publicClient(forHost host: String) -> PeerTubeAPIClient {
        let key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = hostClients[key] { return existing }
        let client = PeerTubeAPIClient(tokenStore: anonymousTokenStore)
        client.baseURL = URL(string: "https://\(key)/")
        hostClients[key] = client
        return client
    }

    /// Loads video metadata, trying each host in order (for fediverse hot / remote origins).
    static func fetchVideoDetail(videoId: String, hosts: [String]) async throws -> (Data, PeerTubeAPIClient) {
        var lastError: Error?
        var tried = Set<String>()
        for host in hosts {
            let key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, tried.insert(key).inserted else { continue }

            if let cached = FederatedVideoDetailCache.data(host: key, videoId: videoId) {
                return (cached, publicClient(forHost: key))
            }

            let client = publicClient(forHost: key)
            do {
                let data = try await throttledVideoDetailRequest(client: client, host: key, videoId: videoId)
                FederatedVideoDetailCache.store(host: key, videoId: videoId, data: data)
                return (data, client)
            } catch {
                // Try the next host on any failure (HTTP error, rate limit, or transport/TLS
                // error — e.g. an expired cert on the index host). The media origin is usually
                // the authoritative fallback.
                lastError = error
                continue
            }
        }
        if let lastError { throw lastError }
        throw APIError.invalidInput("No API host for video.")
    }

    /// Channel avatars from a cached or throttled video detail fetch.
    static func fetchChannelAvatars(videoId: String, host: String) async -> [ActorImage]? {
        let key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let cached = FederatedVideoDetailCache.channelAvatars(host: key, videoId: videoId) {
            return cached
        }
        do {
            _ = try await fetchVideoDetail(videoId: videoId, hosts: [key])
            return FederatedVideoDetailCache.channelAvatars(host: key, videoId: videoId)
        } catch {
            return nil
        }
    }

    struct VideoMetadata {
        var views: Int?
        var avatars: [ActorImage]?
        var thumbnailURL: String?
    }

    /// View count, channel avatars, and an origin-hosted thumbnail URL from a single cached or
    /// throttled video detail fetch, trying each host in order. Used to enrich fediverse-trending
    /// rows, whose hot-API feed omits the first two and serves thumbnails only from the index host.
    /// Callers pass the media origin first: it is authoritative for the view count, distinct per
    /// video (so requests fan out instead of funneling through one host), and survives an expired
    /// or unavailable index host (e.g. peertube.watch).
    static func fetchVideoMetadata(videoId: String, hosts: [String]) async -> VideoMetadata {
        var tried = Set<String>()
        let cleaned = hosts.compactMap { host -> String? in
            let key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, tried.insert(key).inserted else { return nil }
            return key
        }
        guard !cleaned.isEmpty else { return VideoMetadata() }

        for host in cleaned where FederatedVideoDetailCache.data(host: host, videoId: videoId) != nil {
            return metadata(servedHost: host, videoId: videoId)
        }
        guard let (_, client) = try? await fetchVideoDetail(videoId: videoId, hosts: cleaned),
              let servedHost = client.baseURL?.host?.lowercased(), !servedHost.isEmpty else {
            return VideoMetadata()
        }
        return metadata(servedHost: servedHost, videoId: videoId)
    }

    private static func metadata(servedHost: String, videoId: String) -> VideoMetadata {
        guard let video = FederatedVideoDetailCache.decodedVideo(host: servedHost, videoId: videoId) else {
            return VideoMetadata()
        }
        let rawAvatars = video.channel?.avatars ?? video.account?.avatars
        let thumbnailURL = PeerTubeAssetURL.resolve(
            path: video.thumbnailPath,
            instanceBase: nil,
            federatedHost: servedHost,
            cacheHost: servedHost
        )?.absoluteString
        return VideoMetadata(
            views: video.views,
            avatars: absoluteAvatars(rawAvatars, servedHost: servedHost),
            thumbnailURL: thumbnailURL
        )
    }

    /// Rewrites avatars to absolute URLs on the host that actually served the detail, so tiles
    /// resolve them correctly regardless of which fallback host the data came from.
    private static func absoluteAvatars(_ avatars: [ActorImage]?, servedHost: String) -> [ActorImage]? {
        guard let avatars, !avatars.isEmpty else { return nil }
        let resolved = avatars.compactMap { image -> ActorImage? in
            guard let url = PeerTubeAssetURL.resolve(
                avatars: [image],
                instanceBase: nil,
                federatedHost: servedHost,
                cacheHost: servedHost
            )?.absoluteString else { return nil }
            return ActorImage(
                width: image.width,
                height: image.height,
                path: nil,
                fileUrl: url,
                createdAt: image.createdAt,
                updatedAt: image.updatedAt
            )
        }
        return resolved.isEmpty ? nil : resolved
    }

    static func cachedChannelAvatars(videoId: String, hosts: [String]) -> [ActorImage]? {
        for host in hosts {
            let key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if let avatars = FederatedVideoDetailCache.channelAvatars(host: key, videoId: videoId) {
                return avatars
            }
        }
        return nil
    }

    private static func throttledVideoDetailRequest(
        client: PeerTubeAPIClient,
        host: String,
        videoId: String
    ) async throws -> Data {
        await FederatedOriginThrottle.shared.acquire(host: host)
        do {
            let data = try await performVideoDetailRequest(client: client, videoId: videoId)
            await FederatedOriginThrottle.shared.release(host: host)
            return data
        } catch {
            await FederatedOriginThrottle.shared.release(host: host)
            throw error
        }
    }

    private static func performVideoDetailRequest(client: PeerTubeAPIClient, videoId: String) async throws -> Data {
        do {
            return try await client.rawRequest(.videoDetail(id: videoId))
        } catch let error as APIError {
            if case .httpError(429, _) = error {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await client.rawRequest(.videoDetail(id: videoId))
            }
            throw error
        }
    }

    /// API client + token for playing or loading detail for a search result.
    static func playbackContext(
        for video: Video,
        mode: SearchMode,
        instanceClient: PeerTubeAPIClient,
        accessToken: String?
    ) -> (client: PeerTubeAPIClient, accessToken: String?) {
        switch mode {
        case .instance:
            return (instanceClient, accessToken)
        case .global:
            guard let host = video.originHost else {
                return (sepiaSearch, nil)
            }
            return (publicClient(forHost: host), nil)
        }
    }
}
