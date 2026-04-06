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
                LoginView()
            case .authenticated:
                MainTabView()
            }
        }
        .peerTVAppTheme(appThemeStore.theme)
    }
}
