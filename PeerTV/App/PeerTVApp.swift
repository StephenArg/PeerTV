import AVFoundation
import SwiftUI

/// Receives relaunches for the background download session (see `DownloadManager`).
final class PeerTVAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        // Touching `shared` recreates the session, which is what delivers the pending events.
        DownloadManager.shared.backgroundEventsCompletionHandler = completionHandler
    }
}

@main
struct PeerTVApp: App {
    @UIApplicationDelegateAdaptor(PeerTVAppDelegate.self) private var appDelegate
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
