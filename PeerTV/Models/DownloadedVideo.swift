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
    var id: String { videoId }
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
