import Foundation
import os

/// Handles the PeerTube OAuth 2.0 password flow.
struct OAuthService: Sendable {
    private static let log = Logger(subsystem: "com.peernext.PeerTV", category: "OAuthService")

    let apiClient: PeerTubeAPIClient

    /// Full login flow: fetch client credentials, then exchange username/password for tokens.
    /// Pass a non-nil `otpCode` to include the `x-peertube-otp` header for 2FA-enabled accounts.
    func login(baseURL: URL, username: String, password: String, otpCode: String? = nil) async throws -> OAuthTokenResponse {
        Self.log.notice("login password grant starting host=\(baseURL.host ?? baseURL.absoluteString, privacy: .public) user=\(username, privacy: .public) otp=\(otpCode != nil)")
        do {
            let client: OAuthClientResponse = try await apiClient.request(.oauthClientsLocal)
            let body: [String: String] = [
                "client_id": client.clientId,
                "client_secret": client.clientSecret,
                "grant_type": "password",
                "response_type": "code",
                "username": username,
                "password": password
            ]
            var headers: [String: String] = [:]
            if let otp = otpCode?.trimmingCharacters(in: .whitespaces), !otp.isEmpty {
                headers["x-peertube-otp"] = otp
            }
            let tokens: OAuthTokenResponse = try await apiClient.postForm(.usersToken, body: body, additionalHeaders: headers)
            Self.log.notice("login succeeded; tokens received refreshTokenLength=\(tokens.refreshToken.count)")
            return tokens
        } catch {
            Self.log.error("login failed: \(error.localizedDescription, privacy: .public) type=\(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }

    /// Refresh an existing token.
    func refreshToken(baseURL: URL, refreshToken: String) async throws -> OAuthTokenResponse {
        Self.log.notice("OAuthService.refreshToken starting host=\(baseURL.host ?? baseURL.absoluteString, privacy: .public) refreshTokenLength=\(refreshToken.count)")
        do {
            let client: OAuthClientResponse = try await apiClient.request(.oauthClientsLocal)
            let body: [String: String] = [
                "client_id": client.clientId,
                "client_secret": client.clientSecret,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
            let tokens: OAuthTokenResponse = try await apiClient.postForm(.usersToken, body: body)
            Self.log.notice("OAuthService.refreshToken succeeded; new access token length=\(tokens.accessToken.count)")
            return tokens
        } catch {
            Self.log.error("OAuthService.refreshToken failed: \(error.localizedDescription, privacy: .public) type=\(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }
}
