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
    /// Non-nil when add-account must not proceed (e.g. username already on this instance).
    func addAccountConflictMessage(baseURL: URL, username: String) -> String?
}

extension AccountLoginHost {
    func addAccountConflictMessage(baseURL: URL, username: String) -> String? { nil }
}
