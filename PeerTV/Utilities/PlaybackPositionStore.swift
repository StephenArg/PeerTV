import Foundation

/// Persists video playback positions so users can resume where they left off.
/// Positions are stored per-account to keep servers isolated.
enum PlaybackPositionStore {
    private static let enabledKey = "PeerTV.resumePlaybackEnabled"
    private static let positionsKey = "PeerTV.playbackPositions"

    /// Threshold for considering a video "finished" — if the user is within this
    /// percentage of the total duration, the saved position is cleared.
    static let finishedThreshold: Double = 0.07

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

    /// Saves the playback position (in seconds) for a video.
    /// If the position is within `finishedThreshold` of the total duration, the position is
    /// removed instead (video is considered finished).
    static func save(position: TimeInterval, duration: TimeInterval, videoId: String, accountId: UUID) {
        guard isEnabled else { return }
        let key = storageKey(videoId: videoId, accountId: accountId)
        var dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]

        if duration > 0 {
            let remaining = duration - position
            let threshold = duration * finishedThreshold
            if remaining <= threshold {
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

    /// Returns the count of saved positions (for display in settings).
    static var savedPositionCount: Int {
        let dict = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        return dict.count
    }

    private static func storageKey(videoId: String, accountId: UUID) -> String {
        "\(accountId.uuidString):\(videoId)"
    }
}
