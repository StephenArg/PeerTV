import Foundation

enum DebugFlags {
    static let showAPIExplorer = true

    private static let shuffleTabKey = "debug_shuffle_tab_enabled"

    static var shuffleTabEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: shuffleTabKey) }
        set { UserDefaults.standard.set(newValue, forKey: shuffleTabKey) }
    }
}
