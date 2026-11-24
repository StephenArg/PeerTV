import CryptoKit
import Foundation
import Security

/// How long PeerTV can be in the background before it asks for the PIN again. A fresh launch
/// always asks.
enum AppLockDelay: Int, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 1
    case twoMinutes = 2
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "After 1 minute"
        default: return "After \(rawValue) minutes"
        }
    }

    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

/// A channel hidden everywhere in the app (Settings → Restrictions → Blocked Channels).
struct BlockedChannel: Codable, Identifiable, Hashable {
    /// `name@host`, lowercased. The same channel reached through another server has the same handle.
    let handle: String
    let displayName: String
    let blockedAt: Date

    var id: String { handle }
}

/// Parental controls: a channel block list, hiding of videos their uploader marked sensitive,
/// and a PIN that locks those two settings. Device-wide: it applies to every account and server.
///
/// Blocking a channel never needs the PIN (a parent should be able to do it in one press from
/// the channel page); unblocking, changing the sensitive-video switch and removing the PIN do,
/// while a PIN is set.
@MainActor
final class ContentRestrictions: ObservableObject {
    static let shared = ContentRestrictions()

    nonisolated static let pinHashKey = "PeerTV.restrictions.pinHash"
    nonisolated static let pinSaltKey = "PeerTV.restrictions.pinSalt"
    nonisolated static let hideSensitiveKey = "PeerTV.restrictions.hideSensitive"
    nonisolated static let lockDelayKey = "PeerTV.restrictions.lockDelayMinutes"
    nonisolated static let blockedChannelsKey = "PeerTV.restrictions.blockedChannels"
    nonisolated static let pinLength = 4

    /// True while a PIN is set.
    @Published private(set) var isLocked: Bool
    @Published private(set) var hideSensitive: Bool
    /// Time away before returning to the app asks for the PIN. Defaults to immediately.
    @Published private(set) var lockDelay: AppLockDelay
    @Published private(set) var blockedChannels: [BlockedChannel]

    private let defaults: UserDefaults
    private var blockedHandles: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLocked = defaults.string(forKey: Self.pinHashKey) != nil
        hideSensitive = defaults.bool(forKey: Self.hideSensitiveKey)
        lockDelay = AppLockDelay(rawValue: defaults.integer(forKey: Self.lockDelayKey)) ?? .immediately
        let list: [BlockedChannel] = {
            guard let data = defaults.data(forKey: Self.blockedChannelsKey) else { return [] }
            return (try? JSONDecoder().decode([BlockedChannel].self, from: data)) ?? []
        }()
        blockedChannels = list
        blockedHandles = Set(list.map(\.handle))
    }

    // MARK: Filtering

    /// Read from any context (the request builder adds `nsfw=false` from it).
    nonisolated static func hidesSensitiveVideos(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hideSensitiveKey)
    }

    func isBlocked(handle: String?) -> Bool {
        guard let handle = Self.normalized(handle) else { return false }
        return blockedHandles.contains(handle)
    }

    /// False for videos from a blocked channel, and for sensitive videos while those are hidden.
    func allows(_ video: Video) -> Bool {
        if hideSensitive, video.nsfw == true { return false }
        return !isBlocked(handle: video.channelHandle)
    }

    func filtered(_ videos: [Video]) -> [Video] {
        guard hideSensitive || !blockedHandles.isEmpty else { return videos }
        return videos.filter(allows)
    }

    func filtered(_ channels: [VideoChannel]) -> [VideoChannel] {
        guard !blockedHandles.isEmpty else { return channels }
        return channels.filter { !isBlocked(handle: $0.handle) }
    }

    // MARK: Block list

    func block(handle: String, displayName: String) {
        guard let key = Self.normalized(handle), !blockedHandles.contains(key) else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        blockedChannels.append(BlockedChannel(handle: key, displayName: name.isEmpty ? key : name, blockedAt: Date()))
        blockedHandles.insert(key)
        saveBlockedChannels()
    }

    /// Needs the PIN while locked; returns false when it is wrong.
    @discardableResult
    func unblock(handle: String, pin: String?) -> Bool {
        guard authorize(pin) else { return false }
        guard let key = Self.normalized(handle) else { return true }
        blockedChannels.removeAll { $0.handle == key }
        blockedHandles.remove(key)
        saveBlockedChannels()
        return true
    }

    @discardableResult
    func setLockDelay(_ delay: AppLockDelay, pin: String?) -> Bool {
        guard authorize(pin) else { return false }
        lockDelay = delay
        defaults.set(delay.rawValue, forKey: Self.lockDelayKey)
        return true
    }

    @discardableResult
    func setHideSensitive(_ hide: Bool, pin: String?) -> Bool {
        guard authorize(pin) else { return false }
        hideSensitive = hide
        defaults.set(hide, forKey: Self.hideSensitiveKey)
        return true
    }

    // MARK: PIN

    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy(\.isNumber)
    }

    /// Sets the PIN (first time, or a change when `currentPIN` verifies). Turning the lock on
    /// also hides sensitive videos, which is what the lock is for.
    @discardableResult
    func setPIN(_ pin: String, currentPIN: String? = nil) -> Bool {
        guard Self.isValidPIN(pin), authorize(currentPIN) else { return false }
        let salt = Self.randomSalt()
        defaults.set(salt, forKey: Self.pinSaltKey)
        defaults.set(Self.hash(pin: pin, salt: salt), forKey: Self.pinHashKey)
        let wasLocked = isLocked
        isLocked = true
        if !wasLocked, !hideSensitive {
            hideSensitive = true
            defaults.set(true, forKey: Self.hideSensitiveKey)
        }
        return true
    }

    /// Removes the PIN. Blocked channels and the sensitive-video switch stay as they are.
    @discardableResult
    func removePIN(pin: String?) -> Bool {
        guard authorize(pin) else { return false }
        defaults.removeObject(forKey: Self.pinHashKey)
        defaults.removeObject(forKey: Self.pinSaltKey)
        isLocked = false
        return true
    }

    func verify(_ pin: String?) -> Bool {
        guard let pin, let salt = defaults.string(forKey: Self.pinSaltKey),
              let stored = defaults.string(forKey: Self.pinHashKey) else { return false }
        return Self.hash(pin: pin, salt: salt) == stored
    }

    /// True when no PIN is set, or the given one matches.
    private func authorize(_ pin: String?) -> Bool {
        !isLocked || verify(pin)
    }

    private func saveBlockedChannels() {
        if let data = try? JSONEncoder().encode(blockedChannels) {
            defaults.set(data, forKey: Self.blockedChannelsKey)
        }
    }

    private static func normalized(_ handle: String?) -> String? {
        let trimmed = handle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(pin: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + ":" + pin).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
