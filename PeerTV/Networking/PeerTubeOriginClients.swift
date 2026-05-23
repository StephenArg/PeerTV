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
