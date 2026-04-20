import Foundation

/// One saved PeerTube login (instance + profile metadata). Tokens live in Keychain under the same `id`.
struct AccountRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var baseURL: URL
    var username: String
    var displayName: String?
    var avatarPath: String?
    var lastUsedAt: Date

    var host: String { baseURL.host ?? baseURL.absoluteString }
    var handle: String { "\(username)@\(host)" }

    var title: String {
        if let d = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            return d
        }
        return username.isEmpty ? host : username
    }
}

/// Loads/saves the account list and active id from `UserDefaults`.
enum AccountPersistence {
    static let accountsKey = "PeerTV.accounts.v1"
    static let activeAccountKey = "PeerTV.activeAccountId"

    static func loadAccounts() -> [AccountRecord] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AccountRecord].self, from: data)) ?? []
    }

    static func saveAccounts(_ accounts: [AccountRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: accountsKey)
    }

    static func loadActiveAccountId() -> UUID? {
        guard let s = UserDefaults.standard.string(forKey: activeAccountKey) else { return nil }
        return UUID(uuidString: s)
    }

    static func saveActiveAccountId(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: activeAccountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeAccountKey)
        }
    }

    /// Downloads folder for the active account (or legacy layout if none). Safe from any thread (URLSession delegate).
    static func resolvedDownloadsDirectoryURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        guard let s = UserDefaults.standard.string(forKey: activeAccountKey),
              UUID(uuidString: s) != nil else {
            let dir = caches.appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let accountRoot = caches.appendingPathComponent("Accounts/\(s)", isDirectory: true)
        try? FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        let dir = accountRoot.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
