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
