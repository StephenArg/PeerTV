import Foundation

struct FediverseHotVideosResponse: Decodable {
    let results: [FediverseHotVideo]

    private static let hotAPIBase = URL(string: "https://api.peertube.watch/hot")!

    /// One-shot fetch of trending videos across the fediverse.
    /// - Parameter languageIds: ISO codes in display order; omit `language_id` from the URL when empty.
    static func fetchVideos(languageIds: [String] = []) async throws -> [Video] {
        guard let url = hotAPIURL(languageIds: languageIds) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(FediverseHotVideosResponse.self, from: data)
        return decoded.results.map { $0.toVideo() }
    }

    static func hotAPIURL(languageIds: [String]) -> URL? {
        var components = URLComponents(url: hotAPIBase, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "window_hours", value: "720")]
        if let languageValue = FediverseHotLanguage.queryValue(from: languageIds) {
            queryItems.append(URLQueryItem(name: "language_id", value: languageValue))
        }
        components?.queryItems = queryItems
        return components?.url
    }
}

struct FediverseHotThumbnail: Decodable {
    let width: Int?
    let height: Int?
    let fileUrl: String?
}

struct FediverseHotVideo: Decodable {
    let uuid: String?
    let name: String?
    let title: String?
    let description: String?
    let publishedAt: String?
    let createdAt: String?
    let mediaOrigin: String?
    let publicOrigin: String?
    let channelUrl: String?
    let thumbnailPath: String?
    let thumbnails: [FediverseHotThumbnail]?

    func toVideo() -> Video {
        let host = Self.host(from: mediaOrigin)
        let commentReadHost = Self.host(from: publicOrigin)
        let channelName = Self.channelDisplayName(from: channelUrl)
        let displayTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        return Video(
            id: nil,
            uuid: uuid,
            name: displayTitle,
            description: description,
            duration: nil,
            views: nil,
            likes: nil,
            dislikes: nil,
            createdAt: createdAt,
            publishedAt: publishedAt,
            thumbnailPath: bestThumbnailPath,
            previewPath: nil,
            embedPath: nil,
            channel: VideoChannelSummary(
                id: nil,
                name: channelName,
                displayName: channelName,
                url: channelUrl,
                host: host,
                avatars: nil
            ),
            account: nil,
            privacy: nil,
            streamingPlaylists: nil,
            files: nil,
            commentReadHost: commentReadHost
        )
    }

    private var bestThumbnailPath: String? {
        if let thumbs = thumbnails, !thumbs.isEmpty {
            let best = thumbs.max { ($0.width ?? 0) < ($1.width ?? 0) }
            if let url = best?.fileUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                return url
            }
        }
        if let path = thumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return path
        }
        return nil
    }

    private static func host(from originURL: String?) -> String? {
        let trimmed = originURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return nil
        }
        return host
    }

    private static func channelDisplayName(from channelURL: String?) -> String? {
        let trimmed = channelURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" && $0 != "" }
        guard let last = components.last else { return nil }
        if last.hasSuffix("_channel") {
            return String(last.dropLast("_channel".count))
        }
        return last
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
