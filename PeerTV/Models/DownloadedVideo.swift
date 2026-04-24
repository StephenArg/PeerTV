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
