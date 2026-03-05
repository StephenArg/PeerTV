import Foundation

/// Generic paginated response from PeerTube list endpoints.
struct PaginatedResponse<T: Decodable>: Decodable {
    let total: Int?
    let data: [T]?

    var items: [T] { data ?? [] }
}
