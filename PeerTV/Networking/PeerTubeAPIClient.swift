import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, data: Data)
    case decodingError(Error)
    case unauthorized
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .httpError(let code, _): return "HTTP error \(code)."
        case .decodingError(let err): return "Decoding failed: \(err.localizedDescription)"
        case .unauthorized: return "Authentication required."
        case .unknown(let err): return err.localizedDescription
        }
    }
}

/// Central networking client. Builds requests, attaches auth, decodes responses.
/// Thread-safety: baseURL is only mutated from @MainActor (SessionStore);
/// all other mutable state lives in TokenStore which is already @unchecked Sendable.
final class PeerTubeAPIClient: @unchecked Sendable {
    @MainActor var baseURL: URL?
    private let tokenStore: TokenStore
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(tokenStore: TokenStore, session: URLSession = .shared) {
        self.tokenStore = tokenStore
        self.session = session
    }

    // MARK: - Public

    /// Typed JSON request.
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let data = try await rawRequest(endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Raw data request (useful for debug JSON viewer).
    func rawRequest(_ endpoint: Endpoint) async throws -> Data {
        let base = try await resolvedBaseURL()
        let urlRequest = try buildRequest(endpoint, base: base)
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown(URLError(.badServerResponse))
        }
        if http.statusCode == 401 {
            if let refreshed = try? await refreshToken(base: base) {
                tokenStore.save(accessToken: refreshed.accessToken,
                                refreshToken: refreshed.refreshToken)
                var retry = try buildRequest(endpoint, base: base)
                retry.setValue("Bearer \(refreshed.accessToken)",
                               forHTTPHeaderField: "Authorization")
                let (retryData, retryResp) = try await session.data(for: retry)
                if let retryHttp = retryResp as? HTTPURLResponse,
                   retryHttp.statusCode == 401 {
                    throw APIError.unauthorized
                }
                return retryData
            }
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpError(statusCode: http.statusCode, data: data)
        }
        return data
    }

    /// POST form-encoded body (used by OAuth token endpoint).
    func postForm<T: Decodable>(_ endpoint: Endpoint, body: [String: String]) async throws -> T {
        let base = try await resolvedBaseURL()
        var urlRequest = try buildRequest(endpoint, base: base, skipAuth: true)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded",
                            forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body.urlEncodedData
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.httpError(statusCode: code, data: data)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Simple GET returning Data (e.g., validate an instance URL).
    func getData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.httpError(statusCode: code, data: Data())
        }
        return data
    }

    // MARK: - Private

    @MainActor
    private func resolvedBaseURL() throws -> URL {
        guard let base = baseURL else { throw APIError.invalidURL }
        return base
    }

    private func buildRequest(_ endpoint: Endpoint, base: URL, skipAuth: Bool = false) throws -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(endpoint.path),
                                       resolvingAgainstBaseURL: false)
        let items = endpoint.queryItems
        if !items.isEmpty { components?.queryItems = items }
        guard let url = components?.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        if !skipAuth, let token = tokenStore.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = endpoint.httpBody {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func refreshToken(base: URL) async throws -> OAuthTokenResponse {
        guard let refresh = tokenStore.refreshToken else { throw APIError.unauthorized }
        let oauthClient: OAuthClientResponse = try await request(.oauthClientsLocal)
        let body: [String: String] = [
            "client_id": oauthClient.clientId,
            "client_secret": oauthClient.clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refresh
        ]
        return try await postForm(.usersToken, body: body)
    }
}

// MARK: - Helpers

private extension Dictionary where Key == String, Value == String {
    var urlEncodedData: Data? {
        let encoded = map { key, value in
            "\(key.urlQueryEncoded)=\(value.urlQueryEncoded)"
        }.joined(separator: "&")
        return encoded.data(using: .utf8)
    }
}

private extension String {
    var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
