import Foundation
import Combine

/// Centralized session state that drives the root navigation.
@MainActor
final class SessionStore: ObservableObject {
    enum AppPhase: Equatable {
        case needsInstance
        case needsLogin
        case authenticated
    }

    @Published var phase: AppPhase = .needsInstance
    @Published var baseURL: URL?
    @Published var username: String = ""

    private let instanceKey = "pt_instance_url"

    let tokenStore = TokenStore()
    private(set) lazy var apiClient: PeerTubeAPIClient = PeerTubeAPIClient(tokenStore: tokenStore)
    private(set) lazy var oauthService: OAuthService = OAuthService(apiClient: apiClient)

    init() {
        if let saved = UserDefaults.standard.string(forKey: instanceKey),
           let url = URL(string: saved) {
            baseURL = url
            apiClient.baseURL = url
            if tokenStore.accessToken != nil {
                phase = .authenticated
                Task { await loadUsername() }
            } else {
                phase = .needsLogin
            }
        } else {
            phase = .needsInstance
        }
    }

    func setInstance(_ url: URL) {
        baseURL = url
        apiClient.baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: instanceKey)
        phase = .needsLogin
    }

    func didLogin(tokens: OAuthTokenResponse, username: String) {
        tokenStore.save(accessToken: tokens.accessToken,
                        refreshToken: tokens.refreshToken)
        self.username = username
        phase = .authenticated
    }

    func logout() {
        tokenStore.clear()
        username = ""
        phase = .needsLogin
    }

    func clearInstance() {
        logout()
        baseURL = nil
        UserDefaults.standard.removeObject(forKey: instanceKey)
        phase = .needsInstance
    }

    private func loadUsername() async {
        do {
            let user: UserMe = try await apiClient.request(.usersMe)
            username = user.username
        } catch {
            // Token may be expired; attempt refresh
            if await refreshAndRetry() == false {
                logout()
            }
        }
    }

    /// Returns true if refresh succeeded.
    private func refreshAndRetry() async -> Bool {
        guard let refresh = tokenStore.refreshToken,
              let base = baseURL else { return false }
        do {
            let tokens = try await oauthService.refreshToken(baseURL: base, refreshToken: refresh)
            tokenStore.save(accessToken: tokens.accessToken,
                            refreshToken: tokens.refreshToken)
            let user: UserMe = try await apiClient.request(.usersMe)
            username = user.username
            return true
        } catch {
            return false
        }
    }
}
