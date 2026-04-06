import Foundation

enum DebugFlags {
    static let showAPIExplorer = true

    private static let shuffleTabKey = "debug_shuffle_tab_enabled"
    private static let videoDetailRawJSONKey = "PeerTV.debugVideoDetailRawJSON"

    static var shuffleTabEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: shuffleTabKey) }
        set { UserDefaults.standard.set(newValue, forKey: shuffleTabKey) }
    }

    /// "Show Raw JSON" on video detail (Developer settings). Defaults to on when unset.
    static var showVideoDetailRawJSON: Bool {
        get {
            if UserDefaults.standard.object(forKey: videoDetailRawJSONKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: videoDetailRawJSONKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: videoDetailRawJSONKey) }
    }
}
