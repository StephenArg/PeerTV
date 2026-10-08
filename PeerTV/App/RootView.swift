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
    }
}
