import Foundation

extension Notification.Name {
    /// Posted on the main thread when saved positions are removed outside the player, so tiles can
    /// drop their progress bars. `userInfo["videoId"]` names the video; absent means many changed.
    static let peerTVPlaybackPositionsRemoved = Notification.Name("PeerTV.playbackPositionsRemoved")
}

/// Persists video playback positions so users can resume where they left off.
/// Positions are stored per-account to keep servers isolated.
enum PlaybackPositionStore {
    private static let enabledKey = "PeerTV.resumePlaybackEnabled"
    private static let positionsKey = "PeerTV.playbackPositions"

    /// Resume positions for anonymous browsing (separate from signed-in accounts).
    static let anonymousAccountId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// Threshold for considering a video "finished" — if the user is within this
    /// percentage of the total duration, the saved position is cleared.
    static let finishedThreshold: Double = 0.07

    /// If playback is within this fraction of the start, treat as not started — no resume UI / seek.
    static let startedThreshold: Double = 0.03

    /// In-memory copy of the `positionsKey` dictionary. Tiles read positions on every appearance, and
    /// `UserDefaults.dictionary(forKey:)` copies and bridges the whole dictionary each call.
    private static var cachedPositions: [String: Double]?
    private static let cacheLock = NSLock()

    /// Whether resume playback is enabled. Defaults to true.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    /// Returns the saved playback position (in seconds) for a video, or nil if none exists.
    static func position(for videoId: String, accountId: UUID) -> TimeInterval? {
        guard isEnabled else { return nil }
        let key = storageKey(videoId: videoId, accountId: accountId)
        return loadPositions()[key]
    }

    /// Returns watch progress as a fraction of total duration (0...1) for thumbnail display.
    /// Returns nil when resume is disabled, duration is unknown, or the position is not resumable.
    static func progressFraction(for videoId: String, accountId: UUID, durationSeconds: Int?) -> Double? {
        guard let duration = durationSeconds, duration > 0 else { return nil }
        let stored = position(for: videoId, accountId: accountId)
        guard let effective = effectiveResumePosition(stored: stored, durationSeconds: duration) else {
            return nil
        }
        return min(1, max(0, effective / TimeInterval(duration)))
    }

    /// Returns a resume time only when it is not in the opening or closing window of the video.
    /// When `durationSeconds` is nil or non‑positive, returns `stored` unchanged (caller has no duration yet).
    static func effectiveResumePosition(stored: TimeInterval?, durationSeconds: Int?) -> TimeInterval? {
        guard let pos = stored, pos > 0 else { return nil }
        guard let d = durationSeconds, d > 0 else { return pos }
        let duration = TimeInterval(d)
        let ratio = pos / duration
        if ratio < startedThreshold { return nil }
        let remaining = duration - pos
        if remaining <= duration * finishedThreshold { return nil }
        return pos
    }

    /// Saves the playback position (in seconds) for a video.
    /// If the position is within `finishedThreshold` of the total duration, the position is
    /// removed instead (video is considered finished).
    static func save(position: TimeInterval, duration: TimeInterval, videoId: String, accountId: UUID) {
        guard isEnabled else { return }
        let key = storageKey(videoId: videoId, accountId: accountId)
        var dict = loadPositions()

        if duration > 0 {
            let remaining = duration - position
            let endThreshold = duration * finishedThreshold
            if remaining <= endThreshold {
                dict.removeValue(forKey: key)
                storePositions(dict)
                return
            }
            if position / duration < startedThreshold {
                dict.removeValue(forKey: key)
                storePositions(dict)
                return
            }
        }

        if position > 5 {
            dict[key] = position
        } else {
            dict.removeValue(forKey: key)
        }
        storePositions(dict)
    }

    /// Removes the saved position for a video (e.g., when video finishes).
    static func remove(videoId: String, accountId: UUID) {
        let key = storageKey(videoId: videoId, accountId: accountId)
        var dict = loadPositions()
        dict.removeValue(forKey: key)
        storePositions(dict)
        NotificationCenter.default.post(name: .peerTVPlaybackPositionsRemoved, object: nil, userInfo: ["videoId": videoId])
    }

    /// Removes all saved playback positions.
    static func clearAll() {
        cacheLock.lock()
        cachedPositions = [:]
        cacheLock.unlock()
        UserDefaults.standard.removeObject(forKey: positionsKey)
        NotificationCenter.default.post(name: .peerTVPlaybackPositionsRemoved, object: nil)
    }

    /// Removes saved positions for one account namespace (e.g. anonymous session on sign-out).
    static func clearAll(for accountId: UUID) {
        let prefix = "\(accountId.uuidString):"
        storePositions(loadPositions().filter { !$0.key.hasPrefix(prefix) })
        NotificationCenter.default.post(name: .peerTVPlaybackPositionsRemoved, object: nil)
    }

    /// Clears anonymous-session resume data.
    static func clearAnonymousPositions() {
        clearAll(for: anonymousAccountId)
    }

    /// Returns the count of saved positions (for display in settings).
    static var savedPositionCount: Int {
        let anonymousPrefix = "\(anonymousAccountId.uuidString):"
        return loadPositions().filter { !$0.key.hasPrefix(anonymousPrefix) }.count
    }

    static func savedPositionCount(for accountId: UUID) -> Int {
        let prefix = "\(accountId.uuidString):"
        return loadPositions().filter { $0.key.hasPrefix(prefix) }.count
    }

    private static func storageKey(videoId: String, accountId: UUID) -> String {
        "\(accountId.uuidString):\(videoId)"
    }

    private static func loadPositions() -> [String: Double] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedPositions { return cachedPositions }
        let dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        cachedPositions = dict
        return dict
    }

    private static func storePositions(_ dict: [String: Double]) {
        cacheLock.lock()
        cachedPositions = dict
        cacheLock.unlock()
        UserDefaults.standard.set(dict, forKey: positionsKey)
    }
}
