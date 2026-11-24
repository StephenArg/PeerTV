import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var appThemeStore: AppThemeStore
    @Environment(\.scenePhase) private var scenePhase

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
            // Next turn of the run loop, once the app's own window is key.
            DispatchQueue.main.async { AppLockController.shared.lockIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Locked while away, so the PIN screen is already up when the app comes back.
            if phase == .background { AppLockController.shared.lockIfNeeded() }
        }
    }
}
