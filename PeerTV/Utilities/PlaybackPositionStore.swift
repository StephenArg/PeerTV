import Foundation

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
        let dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        return dict[key]
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
        var dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]

        if duration > 0 {
            let remaining = duration - position
            let endThreshold = duration * finishedThreshold
            if remaining <= endThreshold {
                dict.removeValue(forKey: key)
                UserDefaults.standard.set(dict, forKey: positionsKey)
                return
            }
            if position / duration < startedThreshold {
                dict.removeValue(forKey: key)
                UserDefaults.standard.set(dict, forKey: positionsKey)
                return
            }
        }

        if position > 5 {
            dict[key] = position
        } else {
            dict.removeValue(forKey: key)
        }
        UserDefaults.standard.set(dict, forKey: positionsKey)
    }

    /// Removes the saved position for a video (e.g., when video finishes).
    static func remove(videoId: String, accountId: UUID) {
        let key = storageKey(videoId: videoId, accountId: accountId)
        var dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        dict.removeValue(forKey: key)
        UserDefaults.standard.set(dict, forKey: positionsKey)
    }

    /// Removes all saved playback positions.
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: positionsKey)
    }

    /// Removes saved positions for one account namespace (e.g. anonymous session on sign-out).
    static func clearAll(for accountId: UUID) {
        let prefix = "\(accountId.uuidString):"
        var dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        dict = dict.filter { !$0.key.hasPrefix(prefix) }
        UserDefaults.standard.set(dict, forKey: positionsKey)
    }

    /// Clears anonymous-session resume data.
    static func clearAnonymousPositions() {
        clearAll(for: anonymousAccountId)
    }

    /// Returns the count of saved positions (for display in settings).
    static var savedPositionCount: Int {
        let dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        let anonymousPrefix = "\(anonymousAccountId.uuidString):"
        return dict.filter { !$0.key.hasPrefix(anonymousPrefix) }.count
    }

    static func savedPositionCount(for accountId: UUID) -> Int {
        let prefix = "\(accountId.uuidString):"
        let dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        return dict.filter { $0.key.hasPrefix(prefix) }.count
    }

    private static func storageKey(videoId: String, accountId: UUID) -> String {
        "\(accountId.uuidString):\(videoId)"
    }
}
