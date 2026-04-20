import SwiftUI

@MainActor
final class AddAccountFlowModel: ObservableObject, AccountLoginHost {
    weak var session: SessionStore?

    let apiClient: PeerTubeAPIClient
    let oauthService: OAuthService

    @Published var baseURL: URL?

    init() {
        let stagingTokenStore = TokenStore(accountId: UUID())
        apiClient = PeerTubeAPIClient(tokenStore: stagingTokenStore)
        oauthService = OAuthService(apiClient: apiClient)
    }

    func setInstance(_ url: URL) {
        baseURL = url
        apiClient.baseURL = url
    }

    func clearInstance() {
        baseURL = nil
        apiClient.baseURL = nil
    }

    func didLogin(tokens: OAuthTokenResponse, username: String) {
        guard let baseURL, let session else { return }
        session.completeAddAccount(baseURL: baseURL, tokens: tokens, typedUsername: username)
    }
}

struct AddAccountFlowView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var flow = AddAccountFlowModel()
    @State private var showLogin = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    if !showLogin {
                        InstanceSetupScreen(host: flow, onInstanceReady: { showLogin = true })
                    } else {
                        LoginScreen(host: flow)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button("Cancel") {
                    session.cancelAddAccount()
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 80)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
        }
        .presentationBackground(.black)
        .onAppear {
            flow.session = session
        }
        .onChange(of: flow.baseURL) { _, newValue in
            if newValue == nil {
                showLogin = false
            }
        }
    }
}
