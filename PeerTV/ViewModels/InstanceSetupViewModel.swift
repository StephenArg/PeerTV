import Foundation

@MainActor
final class InstanceSetupViewModel: ObservableObject {
    @Published var urlText: String = "https://"
    @Published var isValidating = false
    @Published var errorMessage: String?
    @Published var instanceName: String?

    func validate(using session: SessionStore) async {
        errorMessage = nil
        guard let url = URL(string: urlText),
              url.scheme == "https" || url.scheme == "http" else {
            errorMessage = "Enter a valid URL starting with https://"
            return
        }
        isValidating = true
        defer { isValidating = false }

        let configURL = url.appendingPathComponent("/api/v1/config")
        do {
            let data = try await session.apiClient.getData(from: configURL)
            let config = try JSONDecoder().decode(InstanceConfig.self, from: data)
            instanceName = config.instance?.name
            session.setInstance(url)
        } catch {
            errorMessage = "Could not reach PeerTube instance. Check the URL and try again."
        }
    }
}
