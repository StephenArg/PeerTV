import Foundation

/// Decoded by PeerTubeAPIClient's shared JSONDecoder which uses
/// .convertFromSnakeCase — no explicit CodingKeys needed.

struct OAuthClientResponse: Decodable {
    let clientId: String
    let clientSecret: String
}

struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String?
    let expiresIn: Int?
}
