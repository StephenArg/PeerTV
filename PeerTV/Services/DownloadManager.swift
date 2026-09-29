import Foundation
import Combine
import AVFoundation
import os

// MARK: - Download diagnostics (Console: subsystem com.peernext.PeerTV, category Download)

private let downloadLog = Logger(subsystem: "com.peernext.PeerTV", category: "Download")

/// Host + path + whether `videoFileToken` is present — no secrets in log lines.
private func downloadURLDescription(_ url: URL) -> String {
    let host = url.host ?? ""
    let hasToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .contains(where: { $0.name == "videoFileToken" }) ?? false
    return "\(url.scheme ?? "https")://\(host)\(url.path) videoFileToken=\(hasToken)"
}

// MARK: - Download file validation (reject HTML/JSON error pages and truncated files)

extension DownloadManager {
    /// PeerTube error responses are often a few hundred bytes; real encodes are larger.
    private nonisolated static let minimumVideoFileBytes: Int64 = 4096

    /// True if byte size and magic bytes look like a real media file we can feed to AVPlayer.
    nonisolated static func isPlausibleVideoFile(at fileURL: URL, byteCount: Int64) -> Bool {
        guard byteCount >= minimumVideoFileBytes else { return false }
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v", "mov":
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
            defer { try? handle.close() }
            guard let chunk = try? handle.read(upToCount: 12), chunk.count >= 8 else { return false }
            return chunk.subdata(in: 4..<8) == Data("ftyp".utf8)
        case "webm":
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
            defer { try? handle.close() }
            guard let chunk = try? handle.read(upToCount: 4), chunk.count >= 4 else { return false }
            return chunk == Data([0x1A, 0x45, 0xDF, 0xA3])
        case "ts":
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
            defer { try? handle.close() }
            guard let chunk = try? handle.read(upToCount: 1), chunk.count >= 1 else { return false }
            return chunk[0] == 0x47
        default:
            return byteCount >= 16_384
        }
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var activeDownloads: [String: DownloadProgress] = [:]
    @Published var downloadedVideos: [DownloadedVideo] = [] {
        didSet {
            let ids = Set(downloadedVideos.map(\.videoId))
            if ids != downloadedVideoIds { downloadedVideoIds = ids }
        }
    }
    /// Published on its own so grid tiles can track downloaded state without re-rendering on
    /// every `activeDownloads` progress tick.
    @Published private(set) var downloadedVideoIds: Set<String> = []
    @Published var batchProgress: BatchProgress?

    struct BatchProgress {
        let playlistId: Int
        var total: Int
        var completed: Int
        var currentVideoId: String?
    }

    /// Transfers on this session keep running while the app is suspended, and tvOS relaunches the
    /// app to deliver results if it was terminated meanwhile. Only download tasks run on it.
    static let backgroundSessionIdentifier = "com.peernext.PeerTV.downloads"

    /// Set by the app delegate when tvOS relaunches the app for session events; called once
    /// `urlSessionDidFinishEvents` has delivered them all.
    var backgroundEventsCompletionHandler: (() -> Void)?

    private var urlSession: URLSession!
    private var taskVideoIdMap: [Int: String] = [:]
    private var taskMetaMap: [Int: PendingDownloadMeta] = [:]
    private var speedTrackers: [Int: SpeedTracker] = [:]
    private var activeExportSessions: [String: AVAssetExportSession] = [:]
    private var exportProgressTimers: [String: Timer] = [:]
    private var batchQueue: [String] = []
    private var batchPreference: DownloadQualityPreference?
    private var batchAccessToken: String?
    private var batchApiClient: PeerTubeAPIClient?
    private var batchCurrentVideoId: String?

    /// Per-account offline library; `nil` before any account is active (empty library).
    private var activeDownloadAccountId: UUID?
    /// False until the first `setActiveAccount` at launch, which must not cancel downloads the
    /// background session carried over from the previous process.
    private var hasActivatedAccount = false
    /// Until set, a finished task missing from `taskMetaMap` is a carried-over download not yet
    /// adopted (save it). Afterwards, a missing entry means it was cancelled (discard it).
    private var hasAdoptedRelaunchedTasks = false

    /// `Codable` covers what survives an app relaunch: it's stored as JSON in the task's
    /// `taskDescription`. The token and API client stay in memory, so a download adopted after a
    /// relaunch skips caption sidecars and the 401/403 HLS fallback.
    private struct PendingDownloadMeta: Codable {
        let videoId: String
        let name: String
        let thumbnailPath: String?
        let channelName: String?
        let duration: Int?
        let qualityLabel: String
        let expectedSize: Int64
        /// Master / variant HLS playlist URL for retry when direct `fileUrl` download returns 401/403.
        let fallbackPlaylistURLString: String?
        /// True when file/HLS URLs point at another host than `apiClient` (federation). Local OAuth and
        /// `videoFileToken` from our instance are not valid on the origin server — sending them causes 401.
        let mediaHostDiffersFromAPI: Bool
        /// Library the file is saved into, even if another account is active when it finishes.
        let accountId: UUID?
        var accessToken: String? = nil
        var apiClient: PeerTubeAPIClient? = nil

        private enum CodingKeys: String, CodingKey {
            case videoId, name, thumbnailPath, channelName, duration, qualityLabel, expectedSize
            case fallbackPlaylistURLString, mediaHostDiffersFromAPI, accountId
        }

        var taskDescription: String? {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }

        static func decode(taskDescription: String?) -> PendingDownloadMeta? {
            guard let data = taskDescription?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(PendingDownloadMeta.self, from: data)
        }
    }

    private struct SpeedTracker {
        var lastBytes: Int64 = 0
        var lastTime: Date = Date()
    }

    private nonisolated static func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    private nonisolated static func accountRootURL(for id: UUID) -> URL {
        let root = cachesDirectory().appendingPathComponent("Accounts/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `nil` uses the legacy cache layout. Safe from the URLSession delegate queue.
    private nonisolated static func downloadsDirectoryURL(for accountId: UUID?) -> URL {
        let dir: URL
        if let accountId {
            dir = accountRootURL(for: accountId).appendingPathComponent("Downloads", isDirectory: true)
        } else {
            dir = cachesDirectory().appendingPathComponent("Downloads", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func metadataURL(for accountId: UUID?) -> URL {
        guard let accountId else {
            return cachesDirectory().appendingPathComponent("downloads-metadata.json")
        }
        return accountRootURL(for: accountId).appendingPathComponent("downloads-metadata.json")
    }

    /// When no account is active, uses legacy cache layout (empty until an account activates).
    private func downloadsDirectoryURL() -> URL {
        Self.downloadsDirectoryURL(for: activeDownloadAccountId)
    }

    private func metadataURL() -> URL {
        Self.metadataURL(for: activeDownloadAccountId)
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 4
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        Task { await adoptRelaunchedTasks() }
    }

    /// Rebuilds bookkeeping for downloads the background session kept running while the
    /// previous process was suspended or terminated.
    private func adoptRelaunchedTasks() async {
        let tasks = await urlSession.allTasks
        for task in tasks where taskMetaMap[task.taskIdentifier] == nil {
            guard task.state == .running || task.state == .suspended else { continue }
            guard let meta = PendingDownloadMeta.decode(taskDescription: task.taskDescription) else {
                // No way to name or file the result.
                task.cancel()
                continue
            }
            taskVideoIdMap[task.taskIdentifier] = meta.videoId
            taskMetaMap[task.taskIdentifier] = meta
            speedTrackers[task.taskIdentifier] = SpeedTracker(lastBytes: task.countOfBytesReceived, lastTime: Date())
            if task.state == .suspended { task.resume() }
            downloadLog.notice("adopted background download videoId=\(meta.videoId, privacy: .public)")
        }
        hasAdoptedRelaunchedTasks = true
        publishAdoptedDownloads()
    }

    /// Lists adopted downloads that belong to the active account in `activeDownloads`.
    private func publishAdoptedDownloads() {
        for (taskId, meta) in taskMetaMap where meta.accountId == activeDownloadAccountId {
            guard activeDownloads[meta.videoId] == nil,
                  !downloadedVideoIds.contains(meta.videoId) else { continue }
            activeDownloads[meta.videoId] = DownloadProgress(
                videoId: meta.videoId,
                qualityLabel: meta.qualityLabel,
                totalBytes: meta.expectedSize,
                receivedBytes: speedTrackers[taskId]?.lastBytes ?? 0,
                bytesPerSecond: 0,
                state: .downloading
            )
        }
    }

    /// Moves pre-multi-account `Caches/Downloads` + `downloads-metadata.json` into `Caches/Accounts/<id>/`.
    func migrateLegacyDownloadsIfNeeded(intoAccountId id: UUID) {
        let fm = FileManager.default
        let caches = Self.cachesDirectory()
        let legacyDownloads = caches.appendingPathComponent("Downloads", isDirectory: true)
        let legacyMeta = caches.appendingPathComponent("downloads-metadata.json")
        let destRoot = caches.appendingPathComponent("Accounts/\(id.uuidString)", isDirectory: true)
        let destDownloads = destRoot.appendingPathComponent("Downloads", isDirectory: true)
        let destMeta = destRoot.appendingPathComponent("downloads-metadata.json")

        let legacyHasData = fm.fileExists(atPath: legacyMeta.path)
            || (fm.fileExists(atPath: legacyDownloads.path) && (try? fm.contentsOfDirectory(atPath: legacyDownloads.path))?.isEmpty == false)

        guard legacyHasData else { return }

        try? fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        if fm.fileExists(atPath: legacyDownloads.path) {
            if !fm.fileExists(atPath: destDownloads.path) {
                try? fm.moveItem(at: legacyDownloads, to: destDownloads)
            }
        }
        if fm.fileExists(atPath: legacyMeta.path) {
            if !fm.fileExists(atPath: destMeta.path) {
                try? fm.moveItem(at: legacyMeta, to: destMeta)
            }
        }
    }

    /// Loads metadata for the given account (`nil` = no account / empty library). Switching to a
    /// different account cancels in-flight work. The first call at launch and repeat calls for the
    /// same account (session refresh, signing in again) leave running downloads alone.
    func setActiveAccount(_ id: UUID?) {
        if hasActivatedAccount, id == activeDownloadAccountId { return }
        if hasActivatedAccount { cancelAllDownloadActivity() }
        hasActivatedAccount = true
        activeDownloadAccountId = id
        downloadedVideos = []
        if id != nil {
            loadMetadata()
            pruneInvalidDownloadEntries()
        }
        publishAdoptedDownloads()
    }

    private func cancelAllDownloadActivity() {
        cancelPlaylistBatch()
        for videoId in Array(activeExportSessions.keys) {
            activeExportSessions[videoId]?.cancelExport()
            activeExportSessions.removeValue(forKey: videoId)
            exportProgressTimers.removeValue(forKey: videoId)?.invalidate()
        }
        urlSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        taskVideoIdMap.removeAll()
        taskMetaMap.removeAll()
        speedTrackers.removeAll()
        activeDownloads.removeAll()
    }

    // MARK: - Public API

    func startDownload(
        video: Video,
        file: VideoFile,
        qualityLabel: String,
        accessToken: String?,
        apiClient: PeerTubeAPIClient?
    ) {
        let videoId = video.stableId
        guard activeDownloads[videoId] == nil else { return }
        guard !hasValidLocalFile(videoId) else { return }

        // Prefer the static `fileUrl` over `fileDownloadUrl`. On default PeerTube nginx configs
        // the `/download/...` route (fileDownloadUrl) is proxied through the Node backend and hard
        // rate-limited (`proxy_limit_rate 5M`), while the static `/static/web-videos/...` file
        // (fileUrl) only has `limit_rate_after 5M` per connection. Using the static path avoids the
        // proxy bottleneck and roughly matches HLS playback throughput.
        let directURLString = file.fileUrl ?? file.fileDownloadUrl
        let hlsPlaylistString = file.playlistUrl
        // For HLS export fallback, prefer the master playlist over the per-resolution variant;
        // AVAssetExportSession needs the master manifest to load segments correctly.
        let fallbackPlaylistURLString = video.streamingPlaylists?.first?.playlistUrl
            ?? video.hlsPlaylistURL?.absoluteString
            ?? hlsPlaylistString

        let primaryMediaURL: URL? = {
            if let s = directURLString, let u = URL(string: s) { return u }
            if let s = hlsPlaylistString, let u = URL(string: s) { return u }
            if let s = fallbackPlaylistURLString, let u = URL(string: s) { return u }
            return nil
        }()
        let apiHost = apiClient?.baseURL?.host?.lowercased()
        let mediaHostDiffersFromAPI: Bool = {
            guard let ah = apiHost,
                  let mh = primaryMediaURL?.host?.lowercased() else { return false }
            return mh != ah
        }()

        let meta = PendingDownloadMeta(
            videoId: videoId,
            name: video.name ?? "Untitled",
            thumbnailPath: video.thumbnailPath,
            channelName: video.channel?.displayName,
            duration: video.duration,
            qualityLabel: qualityLabel,
            expectedSize: Int64(file.size ?? 0),
            fallbackPlaylistURLString: fallbackPlaylistURLString,
            mediaHostDiffersFromAPI: mediaHostDiffersFromAPI,
            accountId: activeDownloadAccountId,
            accessToken: accessToken,
            apiClient: apiClient
        )

        let federationHost = video.channel?.host ?? video.account?.host
        if let d = directURLString, let fileURL = URL(string: d) {
            let fileHost = fileURL.host?.lowercased()
            let sameOriginAsApi = (fileHost != nil && apiHost != nil && fileHost == apiHost)
            downloadLog.notice(
                "startDownload videoId=\(videoId, privacy: .public) quality=\(qualityLabel, privacy: .public) federationHost=\(federationHost ?? "nil", privacy: .public) apiHost=\(apiHost ?? "nil", privacy: .public) fileHost=\(fileHost ?? "nil", privacy: .public) sameOriginAsApi=\(sameOriginAsApi) mediaHostDiffersFromAPI=\(mediaHostDiffersFromAPI) hasToken=\(accessToken != nil) hasDirectURL=\(true) hasHlsFile=\(hlsPlaylistString != nil) hasMasterFallback=\(fallbackPlaylistURLString != nil)"
            )
        } else {
            downloadLog.notice(
                "startDownload videoId=\(videoId, privacy: .public) quality=\(qualityLabel, privacy: .public) federationHost=\(federationHost ?? "nil", privacy: .public) apiHost=\(apiHost ?? "nil", privacy: .public) mediaHostDiffersFromAPI=\(mediaHostDiffersFromAPI) hasDirectURL=\(false) hasHlsFile=\(hlsPlaylistString != nil) hasMasterFallback=\(fallbackPlaylistURLString != nil)"
            )
        }

        activeDownloads[videoId] = DownloadProgress(
            videoId: videoId,
            qualityLabel: qualityLabel,
            totalBytes: Int64(file.size ?? 0),
            receivedBytes: 0,
            bytesPerSecond: 0,
            state: .downloading
        )

        if let urlString = directURLString, let downloadURL = URL(string: urlString) {
            if mediaHostDiffersFromAPI {
                downloadLog.notice(
                    "federated file host; skip local videoFileToken/OAuth (origin rejects other instance tokens) videoId=\(videoId, privacy: .public) url=\(downloadURLDescription(downloadURL), privacy: .public)"
                )
                beginTask(url: downloadURL, meta: meta, bearerToken: nil)
            } else if let apiClient, let token = accessToken, !token.isEmpty {
                // Many instances return 401 unless `videoFileToken` is on the query, even when the path
                // does not contain "/private/". When logged in, always prefer the token API + Bearer.
                Task {
                    do {
                        let resp: VideoFileTokenResponse = try await apiClient.request(.videoFileToken(id: videoId))
                        var components = URLComponents(url: downloadURL, resolvingAgainstBaseURL: false)!
                        var items = components.queryItems ?? []
                        items.append(URLQueryItem(name: "videoFileToken", value: resp.files.token))
                        components.queryItems = items
                        let tokenizedURL = components.url ?? downloadURL
                        downloadLog.notice(
                            "videoFileToken OK videoId=\(videoId, privacy: .public) begin url=\(downloadURLDescription(tokenizedURL), privacy: .public)"
                        )
                        self.beginTask(url: tokenizedURL, meta: meta, bearerToken: token)
                    } catch {
                        downloadLog.warning(
                            "videoFileToken failed; using direct URL with Bearer only videoId=\(videoId, privacy: .public) error=\(error.localizedDescription, privacy: .public) url=\(downloadURLDescription(downloadURL), privacy: .public)"
                        )
                        self.beginTask(url: downloadURL, meta: meta, bearerToken: token)
                    }
                }
            } else if downloadURL.path.contains("/private/"), let token = accessToken, !token.isEmpty {
                downloadLog.notice(
                    "begin /private/ file URL with Bearer videoId=\(videoId, privacy: .public) url=\(downloadURLDescription(downloadURL), privacy: .public)"
                )
                var request = URLRequest(url: downloadURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                beginTask(request: request, meta: meta)
            } else {
                downloadLog.notice(
                    "begin direct download (no videoFileToken path) videoId=\(videoId, privacy: .public) url=\(downloadURLDescription(downloadURL), privacy: .public) bearer=\(accessToken != nil)"
                )
                beginTask(url: downloadURL, meta: meta, bearerToken: accessToken)
            }
        } else if let hlsString = hlsPlaylistString, let hlsURL = URL(string: hlsString) {
            downloadLog.notice(
                "begin HLS export path videoId=\(videoId, privacy: .public) playlist=\(downloadURLDescription(hlsURL), privacy: .public)"
            )
            beginHLSExport(url: hlsURL, meta: meta, accessToken: effectiveMediaAccessToken(meta))
        } else {
            downloadLog.error(
                "noDownloadableSource videoId=\(videoId, privacy: .public) direct=\(directURLString ?? "nil", privacy: .public) hlsVariant=\(hlsPlaylistString ?? "nil", privacy: .public) masterFallback=\(fallbackPlaylistURLString ?? "nil", privacy: .public)"
            )
            activeDownloads.removeValue(forKey: videoId)
        }
    }

    func cancelDownload(videoId: String) {
        if let taskId = taskVideoIdMap.first(where: { $0.value == videoId })?.key {
            urlSession.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskId })?.cancel()
            }
            taskVideoIdMap.removeValue(forKey: taskId)
            taskMetaMap.removeValue(forKey: taskId)
            speedTrackers.removeValue(forKey: taskId)
        }
        if let session = activeExportSessions.removeValue(forKey: videoId) {
            session.cancelExport()
        }
        exportProgressTimers.removeValue(forKey: videoId)?.invalidate()
        activeDownloads.removeValue(forKey: videoId)
    }

    func removeDownload(videoId: String) {
        let dir = downloadsDirectoryURL()
        if let entry = downloadedVideos.first(where: { $0.videoId == videoId }) {
            let fileURL = dir.appendingPathComponent(entry.localFilename)
            try? FileManager.default.removeItem(at: fileURL)
            if let caps = entry.captionFilenames {
                for (_, fname) in caps {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(fname))
                }
            }
        }
        downloadedVideos.removeAll { $0.videoId == videoId }
        saveMetadata()
    }

    func removeAllDownloads() {
        let dir = downloadsDirectoryURL()
        for entry in downloadedVideos {
            let fileURL = dir.appendingPathComponent(entry.localFilename)
            try? FileManager.default.removeItem(at: fileURL)
            if let caps = entry.captionFilenames {
                for (_, fname) in caps {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(fname))
                }
            }
        }
        downloadedVideos.removeAll()
        saveMetadata()
    }

    /// Offline caption tracks saved next to the downloaded video file.
    func localPeerTubeCaptions(for videoId: String) -> [PeerTubeCaption] {
        guard let entry = downloadedVideos.first(where: { $0.videoId == videoId }),
              let map = entry.captionFilenames, !map.isEmpty else { return [] }
        let dir = downloadsDirectoryURL()
        var out: [PeerTubeCaption] = []
        for (langId, fname) in map {
            let url = dir.appendingPathComponent(fname)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let label = Self.displayLanguageName(for: langId)
            out.append(PeerTubeCaption(
                languageId: langId,
                displayLabel: label,
                automaticallyGenerated: false,
                sourceURL: url
            ))
        }
        return out.sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }
    }

    private static func displayLanguageName(for code: String) -> String {
        if let s = Locale.current.localizedString(forLanguageCode: code) { return s }
        let primary = code.split(separator: "-").first.map(String.init) ?? code
        return Locale.current.localizedString(forLanguageCode: primary) ?? code
    }

    /// Fetches `/videos/{id}/captions` and saves each `.vtt` into the active downloads directory.
    func downloadCaptionSidecars(videoId: String, apiClient: PeerTubeAPIClient, accessToken: String?) async -> [String: String] {
        var result: [String: String] = [:]
        do {
            let data = try await apiClient.rawRequest(.videoCaptions(id: videoId))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let resp = try decoder.decode(VideoCaptionsResponse.self, from: data)
            let list = (resp.data ?? []).peerTubeCaptions(instanceBase: apiClient.baseURL)
            let dir = downloadsDirectoryURL()
            for cap in list {
                var req = URLRequest(url: cap.sourceURL)
                if let token = accessToken, !token.isEmpty,
                   let ih = apiClient.baseURL?.host?.lowercased(),
                   let ph = cap.sourceURL.host?.lowercased(),
                   ih == ph {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let (vttData, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { continue }
                guard !vttData.isEmpty else { continue }
                let fname = "\(videoId)-\(cap.languageId).vtt"
                let dest = dir.appendingPathComponent(fname)
                try vttData.write(to: dest)
                result[cap.languageId] = fname
            }
        } catch {
            downloadLog.notice("caption sidecars skipped videoId=\(videoId, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
        return result
    }

    func localFileURL(for videoId: String) -> URL? {
        guard let entry = downloadedVideos.first(where: { $0.videoId == videoId }) else {
            return nil
        }
        let url = downloadsDirectoryURL().appendingPathComponent(entry.localFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            removeDownload(videoId: videoId)
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard Self.isPlausibleVideoFile(at: url, byteCount: size) else {
            removeDownload(videoId: videoId)
            return nil
        }
        return url
    }

    /// Metadata-only check, safe to call from view bodies. A file removed since the last prune is
    /// caught (and its entry dropped) by `localFileURL(for:)` when playback starts.
    func isDownloaded(_ videoId: String) -> Bool {
        downloadedVideoIds.contains(videoId)
    }

    private func hasValidLocalFile(_ videoId: String) -> Bool {
        localFileURL(for: videoId) != nil
    }

    // MARK: - Batch downloads

    func startPlaylistBatch(
        playlistId: Int,
        videoIds: [String],
        preference: DownloadQualityPreference,
        accessToken: String?,
        apiClient: PeerTubeAPIClient?
    ) {
        let toDownload = videoIds.filter { !hasValidLocalFile($0) && activeDownloads[$0] == nil }
        guard !toDownload.isEmpty else {
            return
        }
        batchQueue = toDownload
        batchPreference = preference
        batchAccessToken = accessToken
        batchApiClient = apiClient
        setBatchCurrentVideoId(nil)
        batchProgress = BatchProgress(playlistId: playlistId, total: toDownload.count, completed: 0, currentVideoId: nil)
        processNextBatchItem()
    }

    func cancelPlaylistBatch() {
        if let current = batchCurrentVideoId {
            cancelDownload(videoId: current)
        }
        batchQueue.removeAll()
        setBatchCurrentVideoId(nil)
        batchPreference = nil
        batchAccessToken = nil
        batchApiClient = nil
        batchProgress = nil
    }

    func removeDownloads(forVideoIds ids: Set<String>) {
        for videoId in ids {
            removeDownload(videoId: videoId)
        }
    }

    private func setBatchCurrentVideoId(_ videoId: String?) {
        batchCurrentVideoId = videoId
        batchProgress?.currentVideoId = videoId
    }

    private func processNextBatchItem() {
        guard !batchQueue.isEmpty else {
            setBatchCurrentVideoId(nil)
            batchPreference = nil
            batchAccessToken = nil
            batchApiClient = nil
            batchProgress = nil
            return
        }
        let videoId = batchQueue.removeFirst()
        if hasValidLocalFile(videoId) || activeDownloads[videoId] != nil {
            batchProgress?.completed += 1
            processNextBatchItem()
            return
        }
        setBatchCurrentVideoId(videoId)
        guard let apiClient = batchApiClient else {
            batchProgress?.completed += 1
            processNextBatchItem()
            return
        }
        Task {
            do {
                let video: Video = try await apiClient.request(.videoDetail(id: videoId))
                guard let preference = self.batchPreference,
                      let (file, label) = pickVideoFile(video: video, preference: preference) else {
                    self.batchProgress?.completed += 1
                    self.processNextBatchItem()
                    return
                }
                self.startDownload(
                    video: video,
                    file: file,
                    qualityLabel: label,
                    accessToken: self.batchAccessToken,
                    apiClient: apiClient
                )
            } catch {
                self.batchProgress?.completed += 1
                self.processNextBatchItem()
            }
        }
    }

    /// Called when any individual download finishes (success or failure) to advance the batch queue.
    private func notifyDownloadFinished(videoId: String) {
        guard var bp = batchProgress, videoId == batchCurrentVideoId else { return }
        bp.completed += 1
        batchProgress = bp
        processNextBatchItem()
    }

    // MARK: - Private

    /// OAuth is only valid on our API host; do not send it to federated origin media URLs.
    private func effectiveMediaAccessToken(_ meta: PendingDownloadMeta) -> String? {
        guard !meta.mediaHostDiffersFromAPI else { return nil }
        guard let t = meta.accessToken, !t.isEmpty else { return nil }
        return t
    }

    private func beginTask(url: URL, meta: PendingDownloadMeta, bearerToken: String?) {
        let effectiveBearer = meta.mediaHostDiffersFromAPI ? nil : bearerToken
        var request = URLRequest(url: url)
        if let token = effectiveBearer, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        beginTask(request: request, meta: meta)
    }

    private func beginTask(request incoming: URLRequest, meta: PendingDownloadMeta) {
        var request = incoming
        if meta.mediaHostDiffersFromAPI {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        if let u = request.url {
            let auth = request.value(forHTTPHeaderField: "Authorization") != nil
            downloadLog.debug(
                "URLSession downloadTask videoId=\(meta.videoId, privacy: .public) url=\(downloadURLDescription(u), privacy: .public) authorizationHeader=\(auth)"
            )
        }
        let task = urlSession.downloadTask(with: request)
        task.taskDescription = meta.taskDescription
        taskVideoIdMap[task.taskIdentifier] = meta.videoId
        taskMetaMap[task.taskIdentifier] = meta
        speedTrackers[task.taskIdentifier] = SpeedTracker()
        task.resume()
    }

    // MARK: - HLS Export

    private func beginHLSExport(url: URL, meta: PendingDownloadMeta, accessToken: String?) {
        // Bearer auth on AVURLAsset applies to all sub-requests (manifest, variant playlists,
        // segments). This is more reliable for AVAssetExportSession than reinjectVideoFileToken,
        // which dynamically rewrites the HLS manifest and can confuse the export pipeline.
        performHLSExport(url: url, meta: meta, accessToken: accessToken)
    }

    private func performHLSExport(url: URL, meta: PendingDownloadMeta, accessToken: String?) {
        let videoId = meta.videoId
        let playbackToken: String? = meta.mediaHostDiffersFromAPI ? nil : accessToken
        let asset = AVPlayerViewControllerRepresentable.makeAsset(
            url: url,
            accessToken: playbackToken,
            instanceBaseURL: meta.apiClient?.baseURL
        )

        Task {
            do {
                let isPlayable = try await asset.load(.isPlayable)
                if !isPlayable {
                    downloadLog.error(
                        "HLS AVAsset not playable videoId=\(videoId, privacy: .public) url=\(downloadURLDescription(url), privacy: .public)"
                    )
                    self.activeDownloads[videoId]?.state = .failed
                    self.notifyDownloadFinished(videoId: videoId)
                    return
                }
            } catch {
                downloadLog.error(
                    "HLS asset load failed videoId=\(videoId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                self.activeDownloads[videoId]?.state = .failed
                self.notifyDownloadFinished(videoId: videoId)
                return
            }

            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                downloadLog.notice(
                    "HLS no AVAssetExportSession; segment fallback videoId=\(videoId, privacy: .public) url=\(downloadURLDescription(url), privacy: .public)"
                )
                self.fallbackToSegmentDownload(masterURL: url, meta: meta, accessToken: playbackToken)
                return
            }

            let downloadsDir = downloadsDirectoryURL()
            if !FileManager.default.fileExists(atPath: downloadsDir.path) {
                try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            }

            let filename = "\(videoId).mp4"
            let outputURL = downloadsDir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: outputURL)

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            self.activeExportSessions[videoId] = exportSession

            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard var dlProgress = self.activeDownloads[videoId] else { return }
                let progress = exportSession.progress
                let totalBytes = meta.expectedSize > 0 ? meta.expectedSize : Int64(100)
                let received = Int64(Double(totalBytes) * Double(progress))
                dlProgress.receivedBytes = received
                dlProgress.totalBytes = totalBytes
                dlProgress.bytesPerSecond = 0
                self.activeDownloads[videoId] = dlProgress
            }
            self.exportProgressTimers[videoId] = timer

            exportSession.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeExportSessions.removeValue(forKey: videoId)
                self.exportProgressTimers.removeValue(forKey: videoId)?.invalidate()

                switch exportSession.status {
                case .completed:
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? meta.expectedSize
                    guard Self.isPlausibleVideoFile(at: outputURL, byteCount: fileSize) else {
                        try? FileManager.default.removeItem(at: outputURL)
                        self.activeDownloads[videoId]?.state = .failed
                        self.notifyDownloadFinished(videoId: videoId)
                        break
                    }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        var capMap: [String: String]? = nil
                        if let client = meta.apiClient {
                            let m = await self.downloadCaptionSidecars(
                                videoId: meta.videoId,
                                apiClient: client,
                                accessToken: meta.accessToken
                            )
                            capMap = m.isEmpty ? nil : m
                        }
                        let entry = DownloadedVideo(
                            videoId: meta.videoId,
                            name: meta.name,
                            thumbnailPath: meta.thumbnailPath,
                            channelName: meta.channelName,
                            duration: meta.duration,
                            qualityLabel: meta.qualityLabel,
                            fileSize: fileSize,
                            localFilename: filename,
                            downloadedAt: Date(),
                            captionFilenames: capMap
                        )
                        self.activeDownloads.removeValue(forKey: videoId)
                        self.downloadedVideos.removeAll { $0.videoId == videoId }
                        self.downloadedVideos.append(entry)
                        self.saveMetadata()
                        self.notifyDownloadFinished(videoId: videoId)
                    }

                case .cancelled:
                    self.activeDownloads.removeValue(forKey: videoId)
                    try? FileManager.default.removeItem(at: outputURL)
                    self.notifyDownloadFinished(videoId: videoId)

                case .failed:
                    let err = exportSession.error?.localizedDescription ?? "nil"
                    downloadLog.warning(
                        "HLS AVAssetExportSession failed videoId=\(videoId, privacy: .public) error=\(err, privacy: .public) → segment fallback"
                    )
                    try? FileManager.default.removeItem(at: outputURL)
                    self.fallbackToSegmentDownload(masterURL: url, meta: meta, accessToken: playbackToken)

                default:
                    break
                }
            }
            }
        }
    }

    private func fallbackToSegmentDownload(masterURL: URL, meta: PendingDownloadMeta, accessToken: String?) {
        let videoId = meta.videoId
        activeDownloads[videoId] = DownloadProgress(
            videoId: videoId,
            qualityLabel: meta.qualityLabel,
            totalBytes: meta.expectedSize > 0 ? meta.expectedSize : 1,
            receivedBytes: 0,
            bytesPerSecond: 0,
            state: .downloading
        )
        downloadHLSSegments(masterURL: masterURL, meta: meta, accessToken: accessToken)
    }

    // MARK: - Manual HLS Segment Download

    private func fetchDataWithAuth(url: URL, accessToken: String?) async throws -> Data {
        var request = URLRequest(url: url)
        if let token = accessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.lastPathComponent)"
            ])
        }
        return data
    }

    private struct M3U8Variant {
        let url: URL
        let bandwidth: Int?
        let resolutionHeight: Int?
    }

    private func parseM3U8Variants(content: String, baseURL: URL) -> [M3U8Variant] {
        var variants: [M3U8Variant] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                var bandwidth: Int?
                var height: Int?
                if let range = attrs.range(of: "BANDWIDTH=") {
                    let sub = attrs[range.upperBound...]
                    bandwidth = Int(sub.prefix(while: { $0.isNumber }))
                }
                if let range = attrs.range(of: "RESOLUTION=") {
                    let sub = attrs[range.upperBound...]
                    let resStr = sub.prefix(while: { $0 != "," && $0 != "\n" && $0 != " " })
                    if let xIdx = resStr.lastIndex(of: "x") {
                        height = Int(resStr[resStr.index(after: xIdx)...])
                    }
                }
                i += 1
                while i < lines.count {
                    let urlLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !urlLine.isEmpty && !urlLine.hasPrefix("#") {
                        if let resolved = URL(string: urlLine, relativeTo: baseURL) {
                            variants.append(M3U8Variant(url: resolved.absoluteURL, bandwidth: bandwidth, resolutionHeight: height))
                        }
                        break
                    }
                    i += 1
                }
            }
            i += 1
        }
        return variants
    }

    private struct M3U8SegmentInfo {
        let initSegmentURL: URL?
        let segmentURLs: [URL]
    }

    private func parseM3U8Segments(content: String, baseURL: URL) -> M3U8SegmentInfo {
        var initURL: URL?
        var segments: [URL] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-MAP:") {
                if let uriRange = trimmed.range(of: "URI=\"") {
                    let afterURI = trimmed[uriRange.upperBound...]
                    if let endQuote = afterURI.firstIndex(of: "\"") {
                        let uriStr = String(afterURI[..<endQuote])
                        initURL = URL(string: uriStr, relativeTo: baseURL)?.absoluteURL
                    }
                }
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                if let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                    segments.append(url)
                }
            }
        }

        return M3U8SegmentInfo(initSegmentURL: initURL, segmentURLs: segments)
    }

    private func downloadHLSSegments(masterURL: URL, meta: PendingDownloadMeta, accessToken: String?) {
        let videoId = meta.videoId

        Task {
            do {
                let masterData = try await fetchDataWithAuth(url: masterURL, accessToken: accessToken)
                guard let masterContent = String(data: masterData, encoding: .utf8) else {
                    throw URLError(.cannotParseResponse)
                }

                let variants = parseM3U8Variants(content: masterContent, baseURL: masterURL)
                let segInfo: M3U8SegmentInfo

                if variants.isEmpty {
                    segInfo = parseM3U8Segments(content: masterContent, baseURL: masterURL)
                } else {
                    let targetHeight = Int(meta.qualityLabel.filter { $0.isNumber }) ?? 480
                    let chosen = variants.sorted {
                        abs(($0.resolutionHeight ?? 0) - targetHeight) < abs(($1.resolutionHeight ?? 0) - targetHeight)
                    }.first!

                    let variantData = try await fetchDataWithAuth(url: chosen.url, accessToken: accessToken)
                    guard let variantContent = String(data: variantData, encoding: .utf8) else {
                        throw URLError(.cannotParseResponse)
                    }
                    segInfo = parseM3U8Segments(content: variantContent, baseURL: chosen.url)
                }

                guard !segInfo.segmentURLs.isEmpty else {
                    self.activeDownloads[videoId]?.state = .failed
                    self.notifyDownloadFinished(videoId: videoId)
                    return
                }

                try await downloadAndConcatenateSegments(segInfo: segInfo, meta: meta, accessToken: accessToken)

            } catch {
                downloadLog.error(
                    "HLS segment pipeline failed videoId=\(videoId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                self.activeDownloads[videoId]?.state = .failed
                self.notifyDownloadFinished(videoId: videoId)
            }
        }
    }

    private func downloadAndConcatenateSegments(
        segInfo: M3U8SegmentInfo,
        meta: PendingDownloadMeta,
        accessToken: String?
    ) async throws {
        let videoId = meta.videoId
        let hasFMP4Init = segInfo.initSegmentURL != nil
        let filename = "\(videoId).mp4"

        let downloadsDir = downloadsDirectoryURL()
        if !FileManager.default.fileExists(atPath: downloadsDir.path) {
            try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        }

        let outputURL = downloadsDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)

        var totalBytesWritten: Int64 = 0
        let totalSegments = segInfo.segmentURLs.count
        let startTime = Date()

        if let initURL = segInfo.initSegmentURL {
            let initData = try await fetchDataWithAuth(url: initURL, accessToken: accessToken)
            handle.write(initData)
            totalBytesWritten += Int64(initData.count)
        }

        for (i, segURL) in segInfo.segmentURLs.enumerated() {
            guard self.activeDownloads[videoId]?.state == .downloading else {
                try? handle.close()
                try? FileManager.default.removeItem(at: outputURL)
                return
            }

            let segData = try await fetchDataWithAuth(url: segURL, accessToken: accessToken)
            handle.write(segData)
            totalBytesWritten += Int64(segData.count)

            let elapsed = Date().timeIntervalSince(startTime)
            let speed = elapsed > 0 ? Double(totalBytesWritten) / elapsed : 0
            let fractionDone = Double(i + 1) / Double(totalSegments)
            let estimatedTotal = meta.expectedSize > 0
                ? meta.expectedSize
                : (fractionDone > 0 ? Int64(Double(totalBytesWritten) / fractionDone) : 1)
            self.activeDownloads[videoId]?.totalBytes = estimatedTotal
            self.activeDownloads[videoId]?.receivedBytes = Int64(Double(estimatedTotal) * fractionDone)
            self.activeDownloads[videoId]?.bytesPerSecond = speed
        }

        try handle.close()

        // fMP4 concatenation is already a valid MP4. For MPEG-TS we remux locally.
        if !hasFMP4Init {
            let tsURL = outputURL
            let mp4Filename = "\(videoId).mp4"
            let mp4URL = downloadsDir.appendingPathComponent("\(videoId)-remux.mp4")
            try? FileManager.default.removeItem(at: mp4URL)

            let localAsset = AVURLAsset(url: tsURL)
            if let session = AVAssetExportSession(asset: localAsset, presetName: AVAssetExportPresetPassthrough) {
                session.outputURL = mp4URL
                session.outputFileType = .mp4
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    session.exportAsynchronously { cont.resume() }
                }
                if session.status == .completed,
                   let mp4Size = try? FileManager.default.attributesOfItem(atPath: mp4URL.path)[.size] as? Int64,
                   Self.isPlausibleVideoFile(at: mp4URL, byteCount: mp4Size) {
                    try? FileManager.default.removeItem(at: tsURL)
                    try? FileManager.default.moveItem(at: mp4URL, to: outputURL)
                    finishSegmentDownload(videoId: videoId, meta: meta, outputURL: outputURL, filename: mp4Filename, fileSize: mp4Size)
                    return
                }
                try? FileManager.default.removeItem(at: mp4URL)
            }
            // Rename .mp4 -> .ts and keep as playable TS
            let tsFilename = "\(videoId).ts"
            let tsFinalURL = downloadsDir.appendingPathComponent(tsFilename)
            if outputURL != tsFinalURL {
                try? FileManager.default.moveItem(at: outputURL, to: tsFinalURL)
            }
            finishSegmentDownload(videoId: videoId, meta: meta, outputURL: tsFinalURL, filename: tsFilename, fileSize: totalBytesWritten)
        } else {
            finishSegmentDownload(videoId: videoId, meta: meta, outputURL: outputURL, filename: filename, fileSize: totalBytesWritten)
        }
    }

    private func finishSegmentDownload(videoId: String, meta: PendingDownloadMeta, outputURL: URL, filename: String, fileSize: Int64) {
        guard Self.isPlausibleVideoFile(at: outputURL, byteCount: fileSize) else {
            try? FileManager.default.removeItem(at: outputURL)
            self.activeDownloads[videoId]?.state = .failed
            self.notifyDownloadFinished(videoId: videoId)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            var capMap: [String: String]? = nil
            if let client = meta.apiClient {
                let m = await self.downloadCaptionSidecars(
                    videoId: meta.videoId,
                    apiClient: client,
                    accessToken: meta.accessToken
                )
                capMap = m.isEmpty ? nil : m
            }
            let entry = DownloadedVideo(
                videoId: meta.videoId,
                name: meta.name,
                thumbnailPath: meta.thumbnailPath,
                channelName: meta.channelName,
                duration: meta.duration,
                qualityLabel: meta.qualityLabel,
                fileSize: fileSize,
                localFilename: filename,
                downloadedAt: Date(),
                captionFilenames: capMap
            )
            self.activeDownloads.removeValue(forKey: videoId)
            self.downloadedVideos.removeAll { $0.videoId == videoId }
            self.downloadedVideos.append(entry)
            self.saveMetadata()
            self.notifyDownloadFinished(videoId: videoId)
        }
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL()) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        downloadedVideos = (try? decoder.decode([DownloadedVideo].self, from: data)) ?? []
        pruneInvalidDownloadEntries()
    }

    /// Drops metadata (and files) that are missing, tiny, or not valid media (e.g. old HTTP error saves).
    private func pruneInvalidDownloadEntries() {
        let dir = downloadsDirectoryURL()
        let before = downloadedVideos.count
        downloadedVideos.removeAll { entry in
            let url = dir.appendingPathComponent(entry.localFilename)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else {
                return true
            }
            guard Self.isPlausibleVideoFile(at: url, byteCount: size) else {
                try? FileManager.default.removeItem(at: url)
                return true
            }
            return false
        }
        if before != downloadedVideos.count {
            saveMetadata()
        }
    }

    private func saveMetadata() {
        Self.writeMetadata(downloadedVideos, to: metadataURL())
    }

    private static func writeMetadata(_ entries: [DownloadedVideo], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Adds a finished download to its account's library: the in-memory list for the active
    /// account, otherwise that account's metadata file.
    private func recordCompletedDownload(_ entry: DownloadedVideo, accountId: UUID?) {
        guard accountId == activeDownloadAccountId else {
            let url = Self.metadataURL(for: accountId)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var entries = (try? Data(contentsOf: url))
                .flatMap { try? decoder.decode([DownloadedVideo].self, from: $0) } ?? []
            entries.removeAll { $0.videoId == entry.videoId }
            entries.append(entry)
            Self.writeMetadata(entries, to: url)
            return
        }
        activeDownloads.removeValue(forKey: entry.videoId)
        downloadedVideos.removeAll { $0.videoId == entry.videoId }
        downloadedVideos.append(entry)
        saveMetadata()
    }

    /// Main-actor half of `didFinishDownloadingTo`, after the file was moved to `fileURL`.
    private func finishDirectDownload(taskId: Int, storedMeta: PendingDownloadMeta, fileURL: URL, filename: String) {
        let inMemoryMeta = taskMetaMap[taskId]
        taskVideoIdMap.removeValue(forKey: taskId)
        taskMetaMap.removeValue(forKey: taskId)
        speedTrackers.removeValue(forKey: taskId)

        let meta: PendingDownloadMeta
        if let inMemoryMeta {
            meta = inMemoryMeta
        } else if !hasAdoptedRelaunchedTasks {
            // Carried over from the previous process and finished before adoption ran.
            meta = storedMeta
        } else {
            downloadLog.notice("discarding finished download that was cancelled videoId=\(storedMeta.videoId, privacy: .public)")
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let isActiveAccount = meta.accountId == activeDownloadAccountId

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? meta.expectedSize
        guard Self.isPlausibleVideoFile(at: fileURL, byteCount: fileSize) else {
            downloadLog.error(
                "downloaded file failed validation (wrong type or too small) videoId=\(meta.videoId, privacy: .public) bytes=\(fileSize) pathExt=\(fileURL.pathExtension, privacy: .public)"
            )
            try? FileManager.default.removeItem(at: fileURL)
            if isActiveAccount { activeDownloads[meta.videoId]?.state = .failed }
            notifyDownloadFinished(videoId: meta.videoId)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            var capMap: [String: String]? = nil
            // Sidecars are written into the active account's folder, so only fetch them there.
            if let client = meta.apiClient, isActiveAccount {
                let m = await self.downloadCaptionSidecars(
                    videoId: meta.videoId,
                    apiClient: client,
                    accessToken: meta.accessToken
                )
                capMap = m.isEmpty ? nil : m
            }
            let entry = DownloadedVideo(
                videoId: meta.videoId,
                name: meta.name,
                thumbnailPath: meta.thumbnailPath,
                channelName: meta.channelName,
                duration: meta.duration,
                qualityLabel: meta.qualityLabel,
                fileSize: fileSize,
                localFilename: filename,
                downloadedAt: Date(),
                captionFilenames: capMap
            )
            self.recordCompletedDownload(entry, accountId: meta.accountId)
            self.notifyDownloadFinished(videoId: meta.videoId)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        let http = downloadTask.response as? HTTPURLResponse

        if let http, !(200..<300).contains(http.statusCode) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let videoId = self.taskVideoIdMap[taskId],
                      let meta = self.taskMetaMap[taskId] else { return }

                let authLikeFailure = http.statusCode == 401 || http.statusCode == 403
                // The export fallback needs the in-memory client, which adopted tasks don't have.
                if authLikeFailure, meta.apiClient != nil,
                   let hlsStr = meta.fallbackPlaylistURLString,
                   let hlsURL = URL(string: hlsStr), !hlsStr.isEmpty {
                    let reqURL = downloadTask.originalRequest?.url.map { downloadURLDescription($0) } ?? "nil"
                    downloadLog.warning(
                        "directDownload HTTP \(http.statusCode) videoId=\(videoId, privacy: .public) url=\(reqURL, privacy: .public) → retry HLS export fallback=\(downloadURLDescription(hlsURL), privacy: .public)"
                    )
                    self.taskVideoIdMap.removeValue(forKey: taskId)
                    self.taskMetaMap.removeValue(forKey: taskId)
                    self.speedTrackers.removeValue(forKey: taskId)
                    self.activeDownloads[videoId] = DownloadProgress(
                        videoId: videoId,
                        qualityLabel: meta.qualityLabel,
                        totalBytes: meta.expectedSize > 0 ? meta.expectedSize : 1,
                        receivedBytes: 0,
                        bytesPerSecond: 0,
                        state: .downloading
                    )
                    self.beginHLSExport(url: hlsURL, meta: meta, accessToken: self.effectiveMediaAccessToken(meta))
                    return
                }

                let reqURL = downloadTask.originalRequest?.url.map { downloadURLDescription($0) } ?? "nil"
                downloadLog.error(
                    "directDownload HTTP \(http.statusCode) videoId=\(videoId, privacy: .public) url=\(reqURL, privacy: .public) noHLSFallback=\(meta.fallbackPlaylistURLString == nil)"
                )
                self.activeDownloads[videoId]?.state = .failed
                self.taskVideoIdMap.removeValue(forKey: taskId)
                self.taskMetaMap.removeValue(forKey: taskId)
                self.speedTrackers.removeValue(forKey: taskId)
                self.notifyDownloadFinished(videoId: videoId)
            }
            return
        }

        // The system deletes `location` when this method returns, so the file is moved into the
        // owning account's library here, using metadata stored on the task itself (the in-memory
        // maps may not be rebuilt yet after a relaunch).
        guard let storedMeta = PendingDownloadMeta.decode(taskDescription: downloadTask.taskDescription) else {
            downloadLog.error("finished download has no stored metadata taskId=\(taskId)")
            return
        }

        let suggestedExt = downloadTask.response?.suggestedFilename
            .flatMap { URL(string: $0)?.pathExtension }
        let ext = (suggestedExt?.isEmpty == false) ? suggestedExt! : "mp4"

        let filename = "\(storedMeta.videoId).\(ext)"
        let finalDest = Self.downloadsDirectoryURL(for: storedMeta.accountId).appendingPathComponent(filename)
        do {
            try? FileManager.default.removeItem(at: finalDest)
            try FileManager.default.moveItem(at: location, to: finalDest)
        } catch {
            downloadLog.error(
                "move completed download failed videoId=\(storedMeta.videoId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.taskMetaMap.removeValue(forKey: taskId) != nil else { return }
                self.taskVideoIdMap.removeValue(forKey: taskId)
                self.speedTrackers.removeValue(forKey: taskId)
                if storedMeta.accountId == self.activeDownloadAccountId {
                    self.activeDownloads[storedMeta.videoId]?.state = .failed
                }
                self.notifyDownloadFinished(videoId: storedMeta.videoId)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.finishDirectDownload(taskId: taskId, storedMeta: storedMeta, fileURL: finalDest, filename: filename)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let videoId = self.taskVideoIdMap[taskId] else { return }
            guard var progress = self.activeDownloads[videoId] else { return }
            guard var tracker = self.speedTrackers[taskId] else { return }

            // URLSession fires this callback dozens–hundreds of times per second at multi-MB/s.
            // Publishing `activeDownloads` every time invalidates every SwiftUI view observing the
            // manager, which lags the UI and steals main-thread time from the download. Throttle UI
            // updates to ~0.4s; the completion handler always sets the final state, so skipping the
            // intermediate callbacks is safe.
            let now = Date()
            let elapsed = now.timeIntervalSince(tracker.lastTime)
            guard elapsed >= 0.4 else { return }

            let bytesDelta = totalBytesWritten - tracker.lastBytes
            let speed = elapsed > 0 ? Double(bytesDelta) / elapsed : progress.bytesPerSecond
            tracker.lastBytes = totalBytesWritten
            tracker.lastTime = now
            self.speedTrackers[taskId] = tracker

            progress.receivedBytes = totalBytesWritten
            let currentTotal = progress.totalBytes
            progress.totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : currentTotal
            progress.bytesPerSecond = speed
            self.activeDownloads[videoId] = progress
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskId = task.taskIdentifier
        guard let error else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let videoId = self.taskVideoIdMap[taskId] else { return }
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled {
                downloadLog.debug("download cancelled videoId=\(videoId, privacy: .public)")
                self.activeDownloads.removeValue(forKey: videoId)
            } else {
                downloadLog.error(
                    "download task error videoId=\(videoId, privacy: .public) code=\(ns.code) domain=\(ns.domain, privacy: .public) description=\(error.localizedDescription, privacy: .public)"
                )
                self.activeDownloads[videoId]?.state = .failed
            }
            self.taskVideoIdMap.removeValue(forKey: taskId)
            self.taskMetaMap.removeValue(forKey: taskId)
            self.speedTrackers.removeValue(forKey: taskId)
            self.notifyDownloadFinished(videoId: videoId)
        }
    }

    /// All events queued while the app was in the background have been delivered.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let handler = self.backgroundEventsCompletionHandler
            self.backgroundEventsCompletionHandler = nil
            handler?()
        }
    }
}
