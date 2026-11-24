import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var appThemeStore: AppThemeStore

    var body: some View {
        Group {
            switch session.phase {
            case .needsInstance:
                InstanceSetupView()
            case .needsLogin:
                // The sign-in form needs a server; without one, choose it first.
                if session.baseURL == nil {
                    InstanceSetupView()
                } else {
                    LoginView()
                }
            case .anonymous, .authenticated:
                MainTabView()
                    .id(session.mainTabViewIdentity)
            }
        }
        .peerTVAppTheme(appThemeStore.theme)
        .onAppear {
            // `onAppear` also fires when a full-screen cover or the player closes; only the first
            // one (the launch) locks. Returning from the background is handled by the controller.
            // Next turn of the run loop, once the app's own window is key.
            DispatchQueue.main.async { AppLockController.shared.lockAtLaunchIfNeeded() }
        }
    }
}
