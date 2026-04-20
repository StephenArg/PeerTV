import Foundation
import Combine

/// Minimal surface for instance URL + OAuth login flows (onboarding or “add account”).
@MainActor
protocol AccountLoginHost: AnyObject, ObservableObject {
    var baseURL: URL? { get }
    var apiClient: PeerTubeAPIClient { get }
    var oauthService: OAuthService { get }
    func setInstance(_ url: URL)
    func didLogin(tokens: OAuthTokenResponse, username: String)
    func clearInstance()
}
