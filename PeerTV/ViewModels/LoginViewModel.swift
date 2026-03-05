import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    func login(using session: SessionStore) async {
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter both username and password."
            return
        }
        guard let baseURL = session.baseURL else {
            errorMessage = "No instance configured."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let tokens = try await session.oauthService.login(
                baseURL: baseURL,
                username: username,
                password: password
            )
            session.didLogin(tokens: tokens, username: username)
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }
}
