import Foundation
import Security

struct SavedInternetCredential: Identifiable, Equatable {
    let account: String
    let password: String
    var id: String { account }
}

enum InternetCredentialSaver {
    enum SaveResult {
        case saved
        case failed(String)
    }

    /// Saves an internet password to the user's iCloud Keychain (`kSecAttrSynchronizable`).
    static func save(host: String, account: String, password: String) -> SaveResult {
        let fqdn = normalizedHost(from: host)
        guard !fqdn.isEmpty, !account.isEmpty, !password.isEmpty else {
            return .failed("Missing host, username, or password.")
        }
        guard let passwordData = password.data(using: .utf8) else {
            return .failed("Could not encode password.")
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: fqdn,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
        ]

        let attributes: [String: Any] = [
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTMLForm,
            kSecValueData as String: passwordData,
        ]

        var status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        case errSecItemNotFound:
            var legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: fqdn,
                kSecAttrAccount as String: account,
            ]
            if SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecSuccess {
                legacyQuery[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
                status = SecItemUpdate(legacyQuery as CFDictionary, attributes as CFDictionary)
            } else {
                var addQuery = baseQuery
                addQuery.merge(attributes) { _, new in new }
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
        default:
            break
        }

        if status == errSecSuccess {
            return .saved
        }
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return .failed(message)
        }
        return .failed("Keychain save failed (OSStatus \(status)).")
    }

    /// Loads saved internet passwords for a PeerTube instance host (same host key used when saving).
    static func savedCredentials(forHost host: String) -> [SavedInternetCredential] {
        let withProtocol = loadMatching(host: host, requireHTTPSProtocol: true)
        if !withProtocol.isEmpty { return withProtocol }
        return loadMatching(host: host, requireHTTPSProtocol: false)
    }

    private static func loadMatching(host: String, requireHTTPSProtocol: Bool) -> [SavedInternetCredential] {
        let fqdn = normalizedHost(from: host)
        guard !fqdn.isEmpty else { return [] }

        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: fqdn,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if requireHTTPSProtocol {
            query[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else { return [] }

        let itemDicts: [[String: Any]]
        if let array = result as? [[String: Any]] {
            itemDicts = array
        } else if let single = result as? [String: Any] {
            itemDicts = [single]
        } else {
            return []
        }

        var credentials: [SavedInternetCredential] = []
        for item in itemDicts {
            guard let account = item[kSecAttrAccount as String] as? String,
                  !account.isEmpty,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty else { continue }
            credentials.append(SavedInternetCredential(account: account, password: password))
        }
        return credentials.sorted { $0.account.localizedCaseInsensitiveCompare($1.account) == .orderedAscending }
    }

    /// Removes one saved internet password for the instance host and account name.
    @discardableResult
    static func delete(host: String, account: String) -> Bool {
        let fqdn = normalizedHost(from: host)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fqdn.isEmpty, !trimmedAccount.isEmpty else { return false }

        var deleted = false
        for includeProtocol in [true, false] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: fqdn,
                kSecAttrAccount as String: trimmedAccount,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            if includeProtocol {
                query[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
            }
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                deleted = true
            }
        }
        return deleted
    }

    static func normalizedHost(from host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
    }
}
