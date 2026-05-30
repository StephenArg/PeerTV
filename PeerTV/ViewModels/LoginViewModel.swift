import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
    enum LoginOutcome {
        case success(OAuthTokenResponse)
        case failed
    }

    @Published var username = ""
    @Published var password = ""
    @Published var otpCode = ""
    @Published var needsOTP = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    @discardableResult
    func login(using host: any AccountLoginHost) async -> LoginOutcome {
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter both username and password."
            return .failed
        }
        if needsOTP && otpCode.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "Enter your authenticator code."
            return .failed
        }
        guard let baseURL = host.baseURL else {
            errorMessage = "No instance configured."
            return .failed
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
            return .success(tokens)
        } catch let error as APIError {
            if case .httpError(let code, let data) = error,
               (code == 401 || code == 400),
               let parsed = OAuthTokenError.parse(data),
               parsed.isMissingTwoFactor {
                needsOTP = true
                errorMessage = nil
                return .failed
            }
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
        return .failed
    }
}
