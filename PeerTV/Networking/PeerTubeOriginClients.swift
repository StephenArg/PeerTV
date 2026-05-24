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

    private static let retriableVideoDetailStatuses: Set<Int> = [403, 404, 500, 502, 503]
    private static let rateLimitedStatuses: Set<Int> = [429]

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
                lastError = error
                if case APIError.httpError(let code, _) = error {
                    if retriableVideoDetailStatuses.contains(code) { continue }
                    if rateLimitedStatuses.contains(code) { throw error }
                }
                throw error
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
