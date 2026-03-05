import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: SessionStore

    var body: some View {
        switch session.phase {
        case .needsInstance:
            InstanceSetupView()
        case .needsLogin:
            LoginView()
        case .authenticated:
            MainTabView()
        }
    }
}
