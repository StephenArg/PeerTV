import Foundation
import Security

/// Stores OAuth tokens in the Keychain, namespaced per account id (`access_token.<uuid>`).
final class TokenStore: @unchecked Sendable {
    private let service = "com.peernext.PeerTV"
    private let accountId: UUID

    /// Reserved bucket for pre-login / instance-only state (no row in `AccountRecord` yet).
    static let preLoginAccountId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static let legacyAccessAccount = "access_token"
    private static let legacyRefreshAccount = "refresh_token"

    init(accountId: UUID) {
        self.accountId = accountId
    }

    private var accessTokenAccount: String { "access_token.\(accountId.uuidString)" }
    private var refreshTokenAccount: String { "refresh_token.\(accountId.uuidString)" }

    var accessToken: String? {
        read(account: accessTokenAccount)
    }

    var refreshToken: String? {
        read(account: refreshTokenAccount)
    }

    func save(accessToken: String, refreshToken: String) {
        write(value: accessToken, account: accessTokenAccount)
        write(value: refreshToken, account: refreshTokenAccount)
    }

    func clear() {
        delete(account: accessTokenAccount)
        delete(account: refreshTokenAccount)
    }

    /// Removes both token keychain entries for an account (e.g. sign out).
    static func deleteAllTokens(for accountId: UUID) {
        let store = TokenStore(accountId: accountId)
        store.clear()
    }

    // MARK: - Legacy migration (single global keychain pair)

    static func legacyTokensPresent() -> Bool {
        legacyReadAccess() != nil && legacyReadRefresh() != nil
    }

    static func legacyReadAccess() -> String? {
        readStatic(account: legacyAccessAccount)
    }

    static func legacyReadRefresh() -> String? {
        readStatic(account: legacyRefreshAccount)
    }

    /// Copies legacy `access_token` / `refresh_token` into namespaced keys and deletes legacy items.
    static func migrateLegacyTokens(to accountId: UUID) {
        guard let access = legacyReadAccess(), let refresh = legacyReadRefresh() else { return }
        TokenStore(accountId: accountId).save(accessToken: access, refreshToken: refresh)
        deleteStatic(account: legacyAccessAccount)
        deleteStatic(account: legacyRefreshAccount)
    }

    static func deleteLegacyKeychainItems() {
        deleteStatic(account: legacyAccessAccount)
        deleteStatic(account: legacyRefreshAccount)
    }

    // MARK: - Keychain helpers

    private func write(value: String, account: String) {
        delete(account: account)
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func read(account: String) -> String? {
        Self.readStatic(account: account)
    }

    private func delete(account: String) {
        Self.deleteStatic(account: account)
    }

    private static func readStatic(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.peernext.PeerTV",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteStatic(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.peernext.PeerTV",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
