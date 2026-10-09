import Foundation

struct DownloadedVideo: Codable, Identifiable {
    let videoId: String
    let name: String
    let thumbnailPath: String?
    let channelName: String?
    let duration: Int?
    let qualityLabel: String
    let fileSize: Int64
    let localFilename: String
    let downloadedAt: Date
    /// Language id → local `.vtt` filename in the downloads directory (optional for legacy metadata).
    let captionFilenames: [String: String]?
    var id: String { videoId }

    init(
        videoId: String,
        name: String,
        thumbnailPath: String?,
        channelName: String?,
        duration: Int?,
        qualityLabel: String,
        fileSize: Int64,
        localFilename: String,
        downloadedAt: Date,
        captionFilenames: [String: String]? = nil
    ) {
        self.videoId = videoId
        self.name = name
        self.thumbnailPath = thumbnailPath
        self.channelName = channelName
        self.duration = duration
        self.qualityLabel = qualityLabel
        self.fileSize = fileSize
        self.localFilename = localFilename
        self.downloadedAt = downloadedAt
        self.captionFilenames = captionFilenames
    }
}

struct DownloadProgress {
    let videoId: String
    let qualityLabel: String
    var totalBytes: Int64
    var receivedBytes: Int64
    var bytesPerSecond: Double
    var state: State

    enum State {
        case downloading
        case failed
    }

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(receivedBytes) / Double(totalBytes)
    }
}

/// Sort order for the Downloads list, persisted in `UserDefaults`.
enum DownloadsSort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case name
    case largest
    case longest

    static let defaultsKey = "PeerTV.downloadsSort"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newest: "Recently Downloaded"
        case .oldest: "Oldest First"
        case .name: "Name"
        case .largest: "Largest First"
        case .longest: "Longest First"
        }
    }

    func sorted(_ videos: [DownloadedVideo]) -> [DownloadedVideo] {
        switch self {
        case .newest:
            return videos.sorted { $0.downloadedAt > $1.downloadedAt }
        case .oldest:
            return videos.sorted { $0.downloadedAt < $1.downloadedAt }
        case .name:
            return videos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .largest:
            return videos.sorted { $0.fileSize > $1.fileSize }
        case .longest:
            return videos.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }
}

extension Array where Element == DownloadedVideo {
    /// Bytes on disk across all downloads (caption sidecars are negligible).
    var totalFileSize: Int64 {
        reduce(0) { $0 + $1.fileSize }
    }

    /// e.g. "12 videos · 3.4 GB".
    var storageSummary: String {
        let videos = count == 1 ? "1 video" : "\(count) videos"
        return "\(videos) · \(VideoDownloadBar.formatBytes(totalFileSize))"
    }
}
