import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: SessionStore

    var body: some View {
        let others = session.otherAccountsWithValidTokens()
        return VStack(spacing: 0) {
            LoginScreen(
                host: session,
                onBrowseAnonymously: { session.enterAnonymousMode() }
            )

            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Another saved account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 60)

                    ForEach(others) { acc in
                        Button {
                            session.switchAccount(acc.id)
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle")
                                Text("Continue as \(acc.handle)")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 18)
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.card)
                        .padding(.horizontal, 60)
                    }
                }
                .padding(.bottom, 48)
            }
        }
    }
}
