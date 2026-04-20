import Foundation
import Combine
import os

/// Centralized session state that drives the root navigation.
@MainActor
final class SessionStore: ObservableObject, AccountLoginHost {
    private static let log = Logger(subsystem: "com.peernext.PeerTV", category: "SessionStore")

    static let instanceKey = "pt_instance_url"

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

    @Published private(set) var accounts: [AccountRecord] = []
    @Published private(set) var activeAccountId: UUID?
    @Published var isAddingAccount: Bool = false

    private(set) var tokenStore: TokenStore
    private(set) var apiClient: PeerTubeAPIClient
    private(set) var oauthService: OAuthService

    /// Accounts sorted for Settings (most recently used first).
    var sortedAccounts: [AccountRecord] {
        accounts.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// Stable identity for `MainTabView` so switching accounts recreates the tab hierarchy.
    var mainTabViewIdentity: String {
        activeAccountId?.uuidString ?? "authenticated"
    }

    /// Accounts (excluding `activeAccountId`) that still have tokens — for “use another account” on the login screen.
    func otherAccountsWithValidTokens() -> [AccountRecord] {
        let current = activeAccountId
        return accounts.filter { acc in
            acc.id != current && TokenStore(accountId: acc.id).accessToken != nil
        }
        .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// When true, global `/videos` may use broad privacy/`include` filters (staff only on typical instances).
    var useBroadHomeVideoListing: Bool {
        phase == .authenticated && (userRole?.isAdministratorOrModerator == true)
    }

    init() {
        tokenStore = TokenStore(accountId: TokenStore.preLoginAccountId)
        apiClient = PeerTubeAPIClient(tokenStore: tokenStore)
        oauthService = OAuthService(apiClient: apiClient)

        var loadedAccounts = AccountPersistence.loadAccounts()
        var activeId = AccountPersistence.loadActiveAccountId()

        if loadedAccounts.isEmpty,
           TokenStore.legacyTokensPresent(),
           let urlString = UserDefaults.standard.string(forKey: Self.instanceKey),
           let url = URL(string: urlString) {
            let newId = UUID()
            TokenStore.migrateLegacyTokens(to: newId)
            let record = AccountRecord(
                id: newId,
                baseURL: url,
                username: "",
                displayName: nil,
                avatarPath: nil,
                lastUsedAt: Date()
            )
            loadedAccounts = [record]
            activeId = newId
            AccountPersistence.saveAccounts(loadedAccounts)
            AccountPersistence.saveActiveAccountId(newId)
            DownloadManager.shared.migrateLegacyDownloadsIfNeeded(intoAccountId: newId)
        }

        accounts = loadedAccounts
        activeAccountId = activeId

        applyStoredStateAfterInit()
        syncDownloadManagerAccountContext()
    }

    private func applyStoredStateAfterInit() {
        if accounts.isEmpty {
            if let urlString = UserDefaults.standard.string(forKey: Self.instanceKey),
               let url = URL(string: urlString) {
                baseURL = url
                rebuildNetworking(usingAccountId: TokenStore.preLoginAccountId)
                apiClient.baseURL = url
                if tokenStore.accessToken != nil {
                    Self.log.notice("startup: restored instance URL + pre-login bucket tokens")
                    phase = .authenticated
                    Task { await loadUsername() }
                } else {
                    phase = .needsLogin
                }
            } else {
                baseURL = nil
                rebuildNetworking(usingAccountId: TokenStore.preLoginAccountId)
                phase = .needsInstance
            }
            return
        }

        var resolvedActive = activeAccountId
        if resolvedActive == nil || accounts.first(where: { $0.id == resolvedActive }) == nil {
            resolvedActive = accounts.max(by: { $0.lastUsedAt < $1.lastUsedAt })?.id ?? accounts[0].id
            activeAccountId = resolvedActive
            AccountPersistence.saveActiveAccountId(resolvedActive)
        }

        guard let active = resolvedActive,
              let record = accounts.first(where: { $0.id == active }) else {
            baseURL = nil
            phase = .needsInstance
            return
        }

        baseURL = record.baseURL
        UserDefaults.standard.set(record.baseURL.absoluteString, forKey: Self.instanceKey)

        let access = TokenStore(accountId: active).accessToken
        rebuildNetworking(usingAccountId: active)
        apiClient.baseURL = record.baseURL

        if access != nil {
            username = record.username
            userRole = nil
            phase = .authenticated
            Task { await loadUsername() }
        } else {
            username = record.username
            userRole = nil
            phase = .needsLogin
        }
    }

    private func rebuildNetworking(usingAccountId id: UUID) {
        tokenStore = TokenStore(accountId: id)
        apiClient = PeerTubeAPIClient(tokenStore: tokenStore)
        oauthService = OAuthService(apiClient: apiClient)
        if let baseURL {
            apiClient.baseURL = baseURL
        }
    }

    private func persistAccounts() {
        AccountPersistence.saveAccounts(accounts)
    }

    private func syncDownloadManagerAccountContext() {
        switch phase {
        case .authenticated:
            if let id = activeAccountId {
                DownloadManager.shared.setActiveAccount(id)
            } else {
                DownloadManager.shared.setActiveAccount(nil)
            }
        case .needsLogin:
            if let id = activeAccountId, accounts.contains(where: { $0.id == id }) {
                DownloadManager.shared.setActiveAccount(id)
            } else {
                DownloadManager.shared.setActiveAccount(nil)
            }
        case .needsInstance:
            DownloadManager.shared.setActiveAccount(nil)
        }
    }

    func setInstance(_ url: URL) {
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: Self.instanceKey)
        rebuildNetworking(usingAccountId: TokenStore.preLoginAccountId)
        apiClient.baseURL = url
        phase = .needsLogin
        syncDownloadManagerAccountContext()
    }

    func didLogin(tokens: OAuthTokenResponse, username: String) {
        Self.log.notice("didLogin username=\(username, privacy: .public) refreshTokenSaved=\(!tokens.refreshToken.isEmpty)")
        guard let baseURL else { return }

        if let active = activeAccountId,
           let idx = accounts.firstIndex(where: { $0.id == active }) {
            TokenStore(accountId: active).save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
            var rows = accounts
            rows[idx].username = username
            rows[idx].lastUsedAt = Date()
            accounts = rows
            persistAccounts()
            rebuildNetworking(usingAccountId: active)
            apiClient.baseURL = baseURL
            self.username = username
            userRole = nil
            phase = .authenticated
            Task { await loadUsername() }
            syncDownloadManagerAccountContext()
            return
        }

        let newId = UUID()
        TokenStore(accountId: newId).save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
        let record = AccountRecord(
            id: newId,
            baseURL: baseURL,
            username: username,
            displayName: nil,
            avatarPath: nil,
            lastUsedAt: Date()
        )
        accounts = accounts + [record]
        activeAccountId = newId
        AccountPersistence.saveActiveAccountId(newId)
        persistAccounts()
        rebuildNetworking(usingAccountId: newId)
        apiClient.baseURL = baseURL
        self.username = username
        userRole = nil
        phase = .authenticated
        Task { await loadUsername() }
        syncDownloadManagerAccountContext()
    }


    /// Clears tokens but keeps the account row so the user can sign in again.
    func invalidateSession() {
        if let id = activeAccountId {
            TokenStore.deleteAllTokens(for: id)
        } else {
            tokenStore.clear()
        }
        username = ""
        userRole = nil
        phase = .needsLogin
        syncDownloadManagerAccountContext()
    }

    func logout() {
        invalidateSession()
    }

    func clearInstance() {
        guard accounts.isEmpty else { return }
        TokenStore.deleteAllTokens(for: TokenStore.preLoginAccountId)
        baseURL = nil
        username = ""
        userRole = nil
        UserDefaults.standard.removeObject(forKey: Self.instanceKey)
        rebuildNetworking(usingAccountId: TokenStore.preLoginAccountId)
        phase = .needsInstance
        syncDownloadManagerAccountContext()
    }

    func beginAddAccount() {
        isAddingAccount = true
    }

    func cancelAddAccount() {
        isAddingAccount = false
    }

    func completeAddAccount(baseURL: URL, tokens: OAuthTokenResponse, typedUsername: String) {
        let newId = UUID()
        TokenStore(accountId: newId).save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
        let record = AccountRecord(
            id: newId,
            baseURL: baseURL,
            username: typedUsername,
            displayName: nil,
            avatarPath: nil,
            lastUsedAt: Date()
        )
        accounts = accounts + [record]
        activeAccountId = newId
        AccountPersistence.saveActiveAccountId(newId)
        persistAccounts()
        self.baseURL = baseURL
        UserDefaults.standard.set(baseURL.absoluteString, forKey: Self.instanceKey)
        rebuildNetworking(usingAccountId: newId)
        apiClient.baseURL = baseURL
        username = typedUsername
        userRole = nil
        phase = .authenticated
        isAddingAccount = false
        Task { await loadUsername() }
        syncDownloadManagerAccountContext()
    }

    func switchAccount(_ id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        if activeAccountId == id, phase == .authenticated { return }
        var rows = accounts
        rows[idx].lastUsedAt = Date()
        accounts = rows
        persistAccounts()
        activeAccountId = id
        AccountPersistence.saveActiveAccountId(id)
        let record = accounts[idx]
        baseURL = record.baseURL
        username = record.username
        userRole = nil
        UserDefaults.standard.set(record.baseURL.absoluteString, forKey: Self.instanceKey)
        rebuildNetworking(usingAccountId: id)
        apiClient.baseURL = record.baseURL

        if tokenStore.accessToken != nil {
            phase = .authenticated
            Task { await loadUsername() }
        } else {
            phase = .needsLogin
        }
        syncDownloadManagerAccountContext()
    }

    func signOut(accountId: UUID) {
        TokenStore.deleteAllTokens(for: accountId)
        accounts = accounts.filter { $0.id != accountId }
        persistAccounts()

        let wasActive = activeAccountId == accountId
        if !wasActive {
            syncDownloadManagerAccountContext()
            return
        }

        if let next = accounts.max(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            switchAccount(next.id)
            return
        }

        activeAccountId = nil
        AccountPersistence.saveActiveAccountId(nil)
        baseURL = nil
        username = ""
        userRole = nil
        UserDefaults.standard.removeObject(forKey: Self.instanceKey)
        rebuildNetworking(usingAccountId: TokenStore.preLoginAccountId)
        phase = .needsInstance
        syncDownloadManagerAccountContext()
    }

    private func loadUsername() async {
        do {
            let user: UserMe = try await apiClient.request(.usersMe)
            applyUserMe(user)
            Self.log.notice("loadUsername OK username=\(user.username, privacy: .public) roleId=\(user.role?.id.map(String.init) ?? "nil")")
        } catch {
            Self.log.error("loadUsername failed: \(error.localizedDescription, privacy: .public) type=\(String(describing: type(of: error)), privacy: .public) — attempting OAuth refresh path")
            if await refreshAndRetry() == false {
                Self.log.error("loadUsername: refresh path failed; invalidating session")
                invalidateSession()
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
            tokenStore.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
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
        guard let active = activeAccountId,
              let idx = accounts.firstIndex(where: { $0.id == active }) else { return }
        var rows = accounts
        var row = rows[idx]
        row.username = user.username
        row.displayName = user.displayName ?? user.account?.displayName ?? user.account?.name
        if let list = user.account?.avatars,
           let best = list.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }) {
            row.avatarPath = best.path
        }
        rows[idx] = row
        accounts = rows
        persistAccounts()
    }
}
