import Foundation
import Combine
import os

/// Centralized session state that drives the root navigation.
@MainActor
final class SessionStore: ObservableObject {
    private static let log = Logger(subsystem: "com.peernext.PeerTV", category: "SessionStore")

    enum AppPhase: Equatable {
        case needsInstance
        case needsLogin
        case authenticated
    }

    @Published var phase: AppPhase = .needsInstance
    @Published var baseURL: URL?
    @Published var username: String = ""
    /// Set from `GET /api/v1/users/me` when tokens are valid; cleared on logout.
    @Published private(set) var userRole: UserRole?

    private let instanceKey = "pt_instance_url"

    let tokenStore = TokenStore()
    private(set) lazy var apiClient: PeerTubeAPIClient = PeerTubeAPIClient(tokenStore: tokenStore)
    private(set) lazy var oauthService: OAuthService = OAuthService(apiClient: apiClient)

    /// When true, global `/videos` may use broad privacy/`include` filters (staff only on typical instances).
    var useBroadHomeVideoListing: Bool {
        phase == .authenticated && (userRole?.isAdministratorOrModerator == true)
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: instanceKey),
           let url = URL(string: saved) {
            baseURL = url
            apiClient.baseURL = url
            if tokenStore.accessToken != nil {
                Self.log.notice("startup: restored instance + access token; phase=authenticated (will verify via /users/me)")
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
        Self.log.notice("didLogin username=\(username, privacy: .public) refreshTokenSaved=\(!tokens.refreshToken.isEmpty)")
        tokenStore.save(accessToken: tokens.accessToken,
                        refreshToken: tokens.refreshToken)
        self.username = username
        userRole = nil
        phase = .authenticated
        Task { await loadUsername() }
    }

    func logout() {
        Self.log.notice("logout clearing tokens and returning to needsLogin")
        tokenStore.clear()
        username = ""
        userRole = nil
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
            applyUserMe(user)
            Self.log.notice("loadUsername OK username=\(user.username, privacy: .public) roleId=\(user.role?.id.map(String.init) ?? "nil")")
        } catch {
            Self.log.error("loadUsername failed: \(error.localizedDescription, privacy: .public) type=\(String(describing: type(of: error)), privacy: .public) — attempting OAuth refresh path")
            // Token may be expired; attempt refresh
            if await refreshAndRetry() == false {
                Self.log.error("loadUsername: refresh path failed; logging out")
                logout()
            }
        }
    }

    /// Returns true if refresh succeeded.
    private func refreshAndRetry() async -> Bool {
        guard let refresh = tokenStore.refreshToken,
              let base = baseURL else {
            Self.log.error("refreshAndRetry: missing refresh token or base URL refreshPresent=\(self.tokenStore.refreshToken != nil) basePresent=\(self.baseURL != nil)")
            return false
        }
        do {
            Self.log.notice("refreshAndRetry: calling OAuthService.refreshToken host=\(base.host ?? base.absoluteString, privacy: .public)")
            let tokens = try await oauthService.refreshToken(baseURL: base, refreshToken: refresh)
            tokenStore.save(accessToken: tokens.accessToken,
                            refreshToken: tokens.refreshToken)
            let user: UserMe = try await apiClient.request(.usersMe)
            applyUserMe(user)
            Self.log.notice("refreshAndRetry succeeded username=\(user.username, privacy: .public) roleId=\(user.role?.id.map(String.init) ?? "nil")")
            return true
        } catch {
            Self.log.error("refreshAndRetry failed: \(error.localizedDescription, privacy: .public) type=\(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    private func applyUserMe(_ user: UserMe) {
        username = user.username
        userRole = user.role
    }
}
