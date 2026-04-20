import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: SessionStore

    var body: some View {
        let others = session.otherAccountsWithValidTokens()
        return VStack(spacing: 24) {
            LoginScreen(host: session)

            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Another saved account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(others) { acc in
                        Button {
                            session.switchAccount(acc.id)
                        } label: {
                            Text("Continue as \(acc.handle)")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 600)
                .padding(.top, 8)
            }
        }
    }
}
