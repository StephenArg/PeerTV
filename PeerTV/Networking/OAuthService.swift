import Foundation

/// Handles the PeerTube OAuth 2.0 password flow.
struct OAuthService: Sendable {
    let apiClient: PeerTubeAPIClient

    /// Full login flow: fetch client credentials, then exchange username/password for tokens.
    func login(baseURL: URL, username: String, password: String) async throws -> OAuthTokenResponse {
        let client: OAuthClientResponse = try await apiClient.request(.oauthClientsLocal)
        let body: [String: String] = [
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
            "grant_type": "password",
            "response_type": "code",
            "username": username,
            "password": password
        ]
        return try await apiClient.postForm(.usersToken, body: body)
    }

    /// Refresh an existing token.
    func refreshToken(baseURL: URL, refreshToken: String) async throws -> OAuthTokenResponse {
        let client: OAuthClientResponse = try await apiClient.request(.oauthClientsLocal)
        let body: [String: String] = [
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        return try await apiClient.postForm(.usersToken, body: body)
    }
}
