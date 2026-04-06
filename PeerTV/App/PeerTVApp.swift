import SwiftUI

@main
struct PeerTVApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var appThemeStore = AppThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(appThemeStore)
                .environmentObject(DownloadManager.shared)
        }
    }
}
