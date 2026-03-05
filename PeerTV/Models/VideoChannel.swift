import Foundation

struct VideoChannel: Decodable, Identifiable, Hashable {
    let id: Int?
    let name: String?
    let displayName: String?
    let description: String?
    let support: String?
    let host: String?
    let followersCount: Int?
    let followingCount: Int?
    let createdAt: String?
    let banners: [ActorImage]?
    let avatars: [ActorImage]?
    let ownerAccount: AccountSummary?

    var handle: String {
        if let name = name, let host = host {
            return "\(name)@\(host)"
        }
        return name ?? ""
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: VideoChannel, rhs: VideoChannel) -> Bool { lhs.id == rhs.id }
}
