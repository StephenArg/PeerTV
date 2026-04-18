import Foundation

struct UserMe: Decodable {
    let id: Int?
    let username: String
    let email: String?
    let displayName: String?
    let role: UserRole?
    let account: AccountSummary?
}

struct UserRole: Decodable {
    let id: Int?
    let label: String?
}

// Values from PeerTube `packages/models/src/users/user-role.ts` (order is part of the DB contract).
enum PeerTubeUserRoleID {
    static let administrator = 0
    static let moderator = 1
    static let user = 2
}

extension UserRole {
    /// Administrator or moderator — matches PeerTube API rules for broad video listing parameters (`include`, all privacies).
    var isAdministratorOrModerator: Bool {
        guard let id else { return false }
        return id == PeerTubeUserRoleID.administrator || id == PeerTubeUserRoleID.moderator
    }
}
