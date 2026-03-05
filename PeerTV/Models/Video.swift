import Foundation

struct Video: Decodable, Identifiable, Hashable {
    let id: Int?
    let uuid: String?
    let name: String?
    let description: String?
    let duration: Int?
    let views: Int?
    var likes: Int?
    var dislikes: Int?
    let createdAt: String?
    let publishedAt: String?
    let thumbnailPath: String?
    let previewPath: String?
    let embedPath: String?
    let channel: VideoChannelSummary?
    let account: AccountSummary?
    let privacy: VideoPrivacy?
    let streamingPlaylists: [StreamingPlaylist]?
    let files: [VideoFile]?

    var stableId: String { uuid ?? "\(id ?? 0)" }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stableId)
    }

    static func == (lhs: Video, rhs: Video) -> Bool {
        lhs.stableId == rhs.stableId
    }

    /// Best playback URL: prefer HLS, fall back to web video file.
    var playbackURL: URL? {
        if let hls = streamingPlaylists?.first?.files?.first?.fileUrl ?? streamingPlaylists?.first?.playlistUrl,
           let url = URL(string: hls) {
            return url
        }
        if let fileUrl = files?.first?.fileUrl, let url = URL(string: fileUrl) {
            return url
        }
        return nil
    }

    /// HLS playlist URL (m3u8) when available.
    var hlsPlaylistURL: URL? {
        if let playlist = streamingPlaylists?.first?.playlistUrl,
           let url = URL(string: playlist) {
            return url
        }
        return nil
    }

    var formattedDuration: String {
        guard let d = duration, d > 0 else { return "" }
        let h = d / 3600
        let m = (d % 3600) / 60
        let s = d % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var relativeDate: String? {
        guard let dateStr = publishedAt ?? createdAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: dateStr) ?? {
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            return basic.date(from: dateStr)
        }()
        guard let date else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }

    /// All available resolution options across HLS and web video files,
    /// sorted from highest to lowest resolution.
    var resolutionOptions: [ResolutionOption] {
        var options: [ResolutionOption] = []

        if let hlsFiles = streamingPlaylists?.first?.files {
            for file in hlsFiles {
                guard let resId = file.resolution?.id,
                      let label = file.resolution?.label,
                      let urlStr = file.playlistUrl ?? file.fileUrl,
                      let url = URL(string: urlStr) else { continue }
                options.append(ResolutionOption(resolutionId: resId, label: label, url: url))
            }
        }

        if options.isEmpty, let webFiles = files {
            for file in webFiles {
                guard let resId = file.resolution?.id,
                      let label = file.resolution?.label,
                      let urlStr = file.fileUrl,
                      let url = URL(string: urlStr) else { continue }
                options.append(ResolutionOption(resolutionId: resId, label: label, url: url))
            }
        }

        return options.sorted { ($0.resolutionId) > ($1.resolutionId) }
    }
}

struct ResolutionOption: Identifiable {
    let resolutionId: Int
    let label: String
    let url: URL
    var id: Int { resolutionId }
}

struct StreamingPlaylist: Decodable {
    let id: Int?
    let type: Int?
    let playlistUrl: String?
    let files: [VideoFile]?
}

struct VideoFile: Decodable {
    let id: Int?
    let resolution: VideoResolution?
    let fileUrl: String?
    let fileDownloadUrl: String?
    let playlistUrl: String?
    let size: Int?
    let torrentUrl: String?
    let torrentDownloadUrl: String?
}

struct VideoResolution: Decodable {
    let id: Int?
    let label: String?
}

struct VideoChannelSummary: Decodable {
    let id: Int?
    let name: String?
    let displayName: String?
    let url: String?
    let host: String?
    let avatars: [ActorImage]?
}

struct AccountSummary: Decodable {
    let id: Int?
    let name: String?
    let displayName: String?
    let url: String?
    let host: String?
    let avatars: [ActorImage]?
}

struct ActorImage: Decodable {
    let width: Int?
    let path: String?
    let createdAt: String?
    let updatedAt: String?
}

struct VideoPrivacy: Decodable {
    let id: Int?
    let label: String?
}

struct UserVideoRating: Decodable {
    let videoId: Int?
    let rating: String?
}
