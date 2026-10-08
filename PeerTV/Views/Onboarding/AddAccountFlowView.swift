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

    func addAccountConflictMessage(baseURL: URL, username: String) -> String? {
        session?.addAccountConflictMessage(baseURL: baseURL, username: username)
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
                        InstanceSetupScreen(
                            host: flow,
                            onInstanceReady: { showLogin = true },
                            showsAnonymousEntry: false
                        )
                    } else {
                        LoginScreen(host: flow, showsAnonymousEntry: false)
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

// MARK: - Switch server (anonymous browsing)

/// Validates a server for anonymous browsing on a staging client. The session itself only
/// switches once the picker has closed (see `ServerSwitchFlowView.onSelect`).
@MainActor
final class ServerSwitchFlowModel: ObservableObject, AccountLoginHost {
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

    /// No sign-in happens in this flow.
    func didLogin(tokens: OAuthTokenResponse, username: String) {}
}

/// Server selection while browsing anonymously: type a URL or pick a popular server.
struct ServerSwitchFlowView: View {
    /// Called with the validated server just before the cover closes.
    let onSelect: (URL) -> Void
    @StateObject private var flow = ServerSwitchFlowModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                InstanceSetupScreen(
                    host: flow,
                    onInstanceReady: {
                        if let url = flow.baseURL { onSelect(url) }
                        dismiss()
                    },
                    showsAnonymousEntry: false
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 80)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
        }
        .presentationBackground(.black)
    }
}
