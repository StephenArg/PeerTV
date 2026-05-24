import Foundation

/// In-memory cache for federated `GET /videos/{id}` responses (avoids duplicate peertube.watch hits).
enum FederatedVideoDetailCache {
    private struct Entry {
        let data: Data
        let fetchedAt: Date
    }

    private static let ttl: TimeInterval = 15 * 60
    private static var entries: [String: Entry] = [:]

    static func key(host: String, videoId: String) -> String {
        "\(host.lowercased())|\(videoId)"
    }

    static func data(host: String, videoId: String) -> Data? {
        let k = key(host: host, videoId: videoId)
        guard let entry = entries[k], Date().timeIntervalSince(entry.fetchedAt) < ttl else {
            entries[k] = nil
            return nil
        }
        return entry.data
    }

    static func store(host: String, videoId: String, data: Data) {
        entries[key(host: host, videoId: videoId)] = Entry(data: data, fetchedAt: Date())
    }

    static func decodedVideo(host: String, videoId: String) -> Video? {
        guard let data = data(host: host, videoId: videoId) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Video.self, from: data)
    }

    static func channelAvatars(host: String, videoId: String) -> [ActorImage]? {
        guard let video = decodedVideo(host: host, videoId: videoId) else { return nil }
        let avatars = video.channel?.avatars ?? video.account?.avatars
        guard let avatars, !avatars.isEmpty else { return nil }
        return avatars
    }
}
