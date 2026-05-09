import Foundation
import os

enum APIError: LocalizedError {
    case invalidURL
    case invalidInput(String)
    case httpError(statusCode: Int, data: Data)
    case decodingError(Error)
    case unauthorized
    case missingTwoFactor
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .invalidInput(let message): return message
        case .httpError(let code, let data):
            if let desc = OAuthTokenError.parse(data)?.userMessage { return desc }
            return "HTTP error \(code)."
        case .decodingError(let err): return "Decoding failed: \(err.localizedDescription)"
        case .unauthorized: return "Authentication required."
        case .missingTwoFactor: return "Two-factor authentication code required."
        case .unknown(let err): return err.localizedDescription
        }
    }
}

/// Structured representation of PeerTube's OAuth token error responses.
struct OAuthTokenError {
    let code: String?
    let error: String?
    let errorDescription: String?

    var isMissingTwoFactor: Bool { code == "missing_two_factor" }

    var userMessage: String? {
        errorDescription ?? error
    }

    static func parse(_ data: Data) -> OAuthTokenError? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let code = json["code"] as? String
        let error = json["error"] as? String
        let desc = json["error_description"] as? String
        guard code != nil || error != nil || desc != nil else { return nil }
        return OAuthTokenError(code: code, error: error, errorDescription: desc)
    }
}

/// Central networking client. Builds requests, attaches auth, decodes responses.
/// Thread-safety: baseURL is only mutated from @MainActor (SessionStore);
/// all other mutable state lives in TokenStore which is already @unchecked Sendable.
final class PeerTubeAPIClient: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.peernext.PeerTV", category: "PeerTubeAPI")

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
        let host = base.host ?? base.absoluteString
        return try await performAuthorizedDataRequest(
            base: base,
            host: host,
            logDescription: endpoint.networkLogDescription,
            log401EndpointLabel: endpoint.networkLogDescription
        ) {
            try self.buildRequest(endpoint, base: base)
        }
    }

    /// Creates a playlist (`POST /api/v1/video-playlists` multipart). Uses private visibility by default so no channel is required.
    func createVideoPlaylist(displayName: String, privacy: Int = 3) async throws -> Int {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.invalidInput("Enter a playlist name.")
        }
        let name = String(trimmed.prefix(120))
        let boundary = "PeerTV-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func appendPart(fieldName: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        appendPart(fieldName: "displayName", value: name)
        appendPart(fieldName: "privacy", value: "\(privacy)")
        body.append(Data("--\(boundary)--\r\n".utf8))

        let base = try await resolvedBaseURL()
        let host = base.host ?? base.absoluteString
        let data = try await performAuthorizedDataRequest(
            base: base,
            host: host,
            logDescription: "POST multipart /api/v1/video-playlists",
            log401EndpointLabel: "POST multipart /api/v1/video-playlists"
        ) {
            try self.buildCreatePlaylistMultipartRequest(base: base, boundary: boundary, body: body)
        }
        do {
            let decoded: CreateVideoPlaylistResponse = try decoder.decode(CreateVideoPlaylistResponse.self, from: data)
            return decoded.videoPlaylist.id
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Updates a playlist (`PUT /api/v1/video-playlists/{id}` multipart, same schema as create). `playlistPathId` is the numeric id or playlist UUID (UUID required for some non-public playlists).
    func updateVideoPlaylist(
        playlistPathId: String,
        displayName: String,
        description: String?,
        privacy: Int,
        videoChannelId: Int?
    ) async throws {
        let name = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !name.isEmpty else {
            throw APIError.invalidInput("Playlist name cannot be empty.")
        }
        let boundary = "PeerTV-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func appendPart(fieldName: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        appendPart(fieldName: "displayName", value: name)
        // PUT rejects empty `description`; omit the part so only privacy (etc.) changes apply.
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDescription, !trimmedDescription.isEmpty {
            appendPart(fieldName: "description", value: trimmedDescription)
        }
        appendPart(fieldName: "privacy", value: "\(privacy)")
        if let videoChannelId {
            appendPart(fieldName: "videoChannelId", value: "\(videoChannelId)")
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        let base = try await resolvedBaseURL()
        let host = base.host ?? base.absoluteString
        let descLen = trimmedDescription?.count ?? 0
        let descOmitted = trimmedDescription == nil || trimmedDescription?.isEmpty == true
        Self.log.notice(
            "updateVideoPlaylist request playlistPath=\(playlistPathId, privacy: .public) privacy=\(privacy, privacy: .public) videoChannelId=\(videoChannelId.map(String.init) ?? "nil", privacy: .public) displayNameLen=\(name.count, privacy: .public) descriptionLen=\(descLen, privacy: .public) descriptionOmitted=\(descOmitted, privacy: .public) multipartBytes=\(body.count, privacy: .public) host=\(host, privacy: .public)"
        )
        _ = try await performAuthorizedDataRequest(
            base: base,
            host: host,
            logDescription: "PUT multipart /api/v1/video-playlists/\(playlistPathId)",
            log401EndpointLabel: "PUT multipart /api/v1/video-playlists/\(playlistPathId)"
        ) {
            try self.buildUpdatePlaylistMultipartRequest(
                base: base,
                playlistPathId: playlistPathId,
                boundary: boundary,
                body: body
            )
        }
    }

    private func performAuthorizedDataRequest(
        base: URL,
        host: String,
        logDescription: String,
        log401EndpointLabel: String,
        buildRequest: () throws -> URLRequest
    ) async throws -> Data {
        let urlRequest = try buildRequest()
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown(URLError(.badServerResponse))
        }
        if http.statusCode == 401 {
            Self.log401(
                endpointLabel: log401EndpointLabel,
                host: host,
                data: data,
                hasAccessToken: tokenStore.accessToken != nil,
                hasRefreshToken: tokenStore.refreshToken != nil
            )
            let refreshed: OAuthTokenResponse
            do {
                refreshed = try await refreshToken(base: base)
            } catch {
                Self.log.error("OAuth refresh failed (original request was 401): \(String(describing: error), privacy: .public) localized=\(error.localizedDescription, privacy: .public)")
                throw APIError.unauthorized
            }
            tokenStore.save(accessToken: refreshed.accessToken,
                            refreshToken: refreshed.refreshToken)
            Self.log.notice("OAuth refresh succeeded; retrying original request endpoint=\(logDescription, privacy: .public)")
            var retry = try buildRequest()
            retry.setValue("Bearer \(refreshed.accessToken)",
                           forHTTPHeaderField: "Authorization")
            let (retryData, retryResp) = try await session.data(for: retry)
            if let retryHttp = retryResp as? HTTPURLResponse {
                Self.log.notice("After refresh retry status=\(retryHttp.statusCode) endpoint=\(logDescription, privacy: .public)")
                if retryHttp.statusCode == 401 {
                    Self.log.error("After refresh retry still 401 — token rejected or endpoint requires different auth endpoint=\(logDescription, privacy: .public)")
                    throw APIError.unauthorized
                }
                guard (200..<300).contains(retryHttp.statusCode) else {
                    Self.logHttpFailure(statusCode: retryHttp.statusCode, endpoint: logDescription, host: host, data: retryData)
                    throw APIError.httpError(statusCode: retryHttp.statusCode, data: retryData)
                }
            } else {
                Self.log.error("After refresh retry missing HTTPURLResponse endpoint=\(logDescription, privacy: .public)")
            }
            return retryData
        }
        guard (200..<300).contains(http.statusCode) else {
            Self.logHttpFailure(statusCode: http.statusCode, endpoint: logDescription, host: host, data: data)
            throw APIError.httpError(statusCode: http.statusCode, data: data)
        }
        return data
    }

    private func buildCreatePlaylistMultipartRequest(base: URL, boundary: String, body: Data) throws -> URLRequest {
        var components = URLComponents(
            url: base.appendingPathComponent("/api/v1/video-playlists"),
            resolvingAgainstBaseURL: false
        )
        guard let url = components?.url else { throw APIError.invalidURL }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "POST"
        if let token = tokenStore.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func buildUpdatePlaylistMultipartRequest(
        base: URL,
        playlistPathId: String,
        boundary: String,
        body: Data
    ) throws -> URLRequest {
        var components = URLComponents(
            url: base.appendingPathComponent("/api/v1/video-playlists/\(playlistPathId)"),
            resolvingAgainstBaseURL: false
        )
        guard let url = components?.url else { throw APIError.invalidURL }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "PUT"
        if let token = tokenStore.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// POST form-encoded body (used by OAuth token endpoint).
    func postForm<T: Decodable>(
        _ endpoint: Endpoint,
        body: [String: String],
        additionalHeaders: [String: String] = [:]
    ) async throws -> T {
        let base = try await resolvedBaseURL()
        var urlRequest = try buildRequest(endpoint, base: base, skipAuth: true)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded",
                            forHTTPHeaderField: "Content-Type")
        for (key, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = body.urlEncodedData
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let host = base.host ?? base.absoluteString
            Self.log.error("postForm non-success status=\(code) endpoint=\(endpoint.networkLogDescription, privacy: .public) host=\(host, privacy: .public) bodyPreview=\(Self.truncateForLog(data), privacy: .public)")
            if let oauth = OAuthTokenError.parse(data) {
                Self.log.error("postForm OAuth error code=\(oauth.code ?? "nil", privacy: .public) error=\(oauth.error ?? "nil", privacy: .public) desc=\(oauth.errorDescription ?? "nil", privacy: .public)")
            }
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
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = endpoint.method
        if !skipAuth, let token = tokenStore.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if case .randomVideos = endpoint {
            // PeerTube `random-video-tab` plugin expects these (see client/main.js).
            let lgd = tokenStore.accessToken != nil ? "smack" : "hit"
            request.setValue(lgd, forHTTPHeaderField: "lgd")
            request.setValue("false", forHTTPHeaderField: "mobile")
        }
        if let body = endpoint.httpBody {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func refreshToken(base: URL) async throws -> OAuthTokenResponse {
        let host = base.host ?? base.absoluteString
        Self.log.notice("refreshToken() starting host=\(host, privacy: .public) refreshTokenPresent=\(self.tokenStore.refreshToken != nil)")
        guard let refresh = tokenStore.refreshToken else {
            Self.log.error("refreshToken() aborted: no refresh token in keychain")
            throw APIError.unauthorized
        }
        let oauthClient: OAuthClientResponse = try await request(.oauthClientsLocal)
        let body: [String: String] = [
            "client_id": oauthClient.clientId,
            "client_secret": oauthClient.clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refresh
        ]
        do {
            let tokens: OAuthTokenResponse = try await postForm(.usersToken, body: body)
            Self.log.notice("refreshToken() POST /users/token decoded OK host=\(host, privacy: .public)")
            return tokens
        } catch {
            Self.log.error("refreshToken() POST /users/token failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static func logHttpFailure(statusCode: Int, endpoint: String, host: String, data: Data) {
        let maxChars = (statusCode == 400 || statusCode == 422) ? 2048 : 512
        let preview = truncateForLog(data, maxChars: maxChars)
        switch statusCode {
        case 400:
            Self.log.error("HTTP 400 (bad request) endpoint=\(endpoint, privacy: .public) host=\(host, privacy: .public) bodyPreview=\(preview, privacy: .public)")
        case 403:
            Self.log.notice("HTTP 403 (forbidden) endpoint=\(endpoint, privacy: .public) host=\(host, privacy: .public) bodyPreview=\(preview, privacy: .public)")
        case 404:
            Self.log.notice("HTTP 404 endpoint=\(endpoint, privacy: .public) host=\(host, privacy: .public) bodyPreview=\(preview, privacy: .public)")
        case 422:
            Self.log.error("HTTP 422 (unprocessable) endpoint=\(endpoint, privacy: .public) host=\(host, privacy: .public) bodyPreview=\(preview, privacy: .public)")
        default:
            Self.log.notice("HTTP \(statusCode) endpoint=\(endpoint, privacy: .public) host=\(host, privacy: .public) bodyPreview=\(preview, privacy: .public)")
        }
    }

    private static func log401(
        endpointLabel: String,
        host: String,
        data: Data,
        hasAccessToken: Bool,
        hasRefreshToken: Bool
    ) {
        Self.log.notice("HTTP 401 host=\(host, privacy: .public) endpoint=\(endpointLabel, privacy: .public) accessTokenPresent=\(hasAccessToken) refreshTokenPresent=\(hasRefreshToken) bodyPreview=\(truncateForLog(data), privacy: .public)")
        if let oauth = OAuthTokenError.parse(data) {
            Self.log.error("401 response OAuth fields code=\(oauth.code ?? "nil", privacy: .public) error=\(oauth.error ?? "nil", privacy: .public) desc=\(oauth.errorDescription ?? "nil", privacy: .public)")
        }
    }

    private static func truncateForLog(_ data: Data, maxChars: Int = 512) -> String {
        guard !data.isEmpty else { return "<empty>" }
        let s = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        if s.count <= maxChars { return s }
        return String(s.prefix(maxChars)) + "… (total \(data.count) bytes)"
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
