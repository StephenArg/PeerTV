import Foundation

/// Partial model for GET /api/v1/config — only the fields we care about.
struct InstanceConfig: Decodable {
    let instance: InstanceInfo?
    let serverVersion: String?
}

struct InstanceInfo: Decodable {
    let name: String?
    let shortDescription: String?
}
