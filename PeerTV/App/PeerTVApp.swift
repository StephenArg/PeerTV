import AVFoundation
import SwiftUI

@main
struct PeerTVApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var appThemeStore = AppThemeStore()

    init() {
        // Picture in Picture on tvOS requires a playback session so audio continues
        // after the full-screen player is dismissed into the corner window.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(appThemeStore)
                .environmentObject(DownloadManager.shared)
        }
    }
}
