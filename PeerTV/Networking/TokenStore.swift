import Foundation
import Security

/// Stores OAuth tokens in the Keychain.
final class TokenStore: @unchecked Sendable {
    private let service = "com.peernext.PeerTV"
    private let accessTokenAccount = "access_token"
    private let refreshTokenAccount = "refresh_token"

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
