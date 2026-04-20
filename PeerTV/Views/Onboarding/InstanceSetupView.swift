import SwiftUI

struct InstanceSetupView: View {
    @EnvironmentObject var session: SessionStore

    var body: some View {
        InstanceSetupScreen(host: session, onInstanceReady: nil)
    }
}
