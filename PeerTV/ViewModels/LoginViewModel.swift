import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var otpCode = ""
    @Published var needsOTP = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    func login(using host: any AccountLoginHost) async {
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter both username and password."
            return
        }
        if needsOTP && otpCode.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "Enter your authenticator code."
            return
        }
        guard let baseURL = host.baseURL else {
            errorMessage = "No instance configured."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let tokens = try await host.oauthService.login(
                baseURL: baseURL,
                username: username,
                password: password,
                otpCode: needsOTP ? otpCode : nil
            )
            host.didLogin(tokens: tokens, username: username)
        } catch let error as APIError {
            if case .httpError(let code, let data) = error,
               (code == 401 || code == 400),
               let parsed = OAuthTokenError.parse(data),
               parsed.isMissingTwoFactor {
                needsOTP = true
                errorMessage = nil
                return
            }
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }
}
