import AVFoundation
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
    /// When set (e.g. peertube.watch index from hot API), comment threads may be more complete here than on `originHost`.
    let commentReadHost: String?

    var stableId: String { uuid ?? "\(id ?? 0)" }

    init(
        id: Int?,
        uuid: String?,
        name: String?,
        description: String?,
        duration: Int?,
        views: Int?,
        likes: Int?,
        dislikes: Int?,
        createdAt: String?,
        publishedAt: String?,
        thumbnailPath: String?,
        previewPath: String?,
        embedPath: String?,
        channel: VideoChannelSummary?,
        account: AccountSummary?,
        privacy: VideoPrivacy?,
        streamingPlaylists: [StreamingPlaylist]?,
        files: [VideoFile]?,
        commentReadHost: String? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.description = description
        self.duration = duration
        self.views = views
        self.likes = likes
        self.dislikes = dislikes
        self.createdAt = createdAt
        self.publishedAt = publishedAt
        self.thumbnailPath = thumbnailPath
        self.previewPath = previewPath
        self.embedPath = embedPath
        self.channel = channel
        self.account = account
        self.privacy = privacy
        self.streamingPlaylists = streamingPlaylists
        self.files = files
        self.commentReadHost = commentReadHost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        views = try c.decodeIfPresent(Int.self, forKey: .views)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        dislikes = try c.decodeIfPresent(Int.self, forKey: .dislikes)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        // PeerTube 8.1 deprecated `thumbnailPath` / `previewPath` (null once images are in object
        // storage) in favor of a `thumbnails` array. The server fills the legacy pair with the
        // smallest and largest 16:9 entries, so do the same when it leaves them out.
        let thumbnails = try? c.decodeIfPresent([VideoThumbnail].self, forKey: .thumbnails)
        let legacyThumbnailPath = try c.decodeIfPresent(String.self, forKey: .thumbnailPath)
        let legacyPreviewPath = try c.decodeIfPresent(String.self, forKey: .previewPath)
        thumbnailPath = legacyThumbnailPath?.isEmpty == false
            ? legacyThumbnailPath
            : thumbnails?.fileUrl(widest: false)
        previewPath = legacyPreviewPath?.isEmpty == false
            ? legacyPreviewPath
            : thumbnails?.fileUrl(widest: true)
        embedPath = try c.decodeIfPresent(String.self, forKey: .embedPath)
        channel = try c.decodeIfPresent(VideoChannelSummary.self, forKey: .channel)
        account = try c.decodeIfPresent(AccountSummary.self, forKey: .account)
        privacy = try c.decodeIfPresent(VideoPrivacy.self, forKey: .privacy)
        streamingPlaylists = try c.decodeIfPresent([StreamingPlaylist].self, forKey: .streamingPlaylists)
        files = try c.decodeIfPresent([VideoFile].self, forKey: .files)
        commentReadHost = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, uuid, name, description, duration, views, likes, dislikes
        case createdAt, publishedAt, thumbnailPath, previewPath, thumbnails, embedPath
        case channel, account, privacy, streamingPlaylists, files
    }

    /// Federated origin hostname (no scheme), when the video is not on the connected instance.
    var originHost: String? {
        let host = channel?.host ?? account?.host
        let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// API hosts to try for federated videos (public index first, then media origin).
    var federatedAPIHosts: [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        func append(_ host: String?) {
            let key = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            hosts.append(key)
        }
        append(commentReadHost)
        append(originHost)
        return hosts
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stableId)
    }

    // Compares the fields that drive tile/detail rendering — not just `stableId`. SwiftUI uses a
    // view's stored Equatable properties to decide whether to re-render; an identity-only `==`
    // makes enriched rows (same id, new views/avatars/thumbnail) look unchanged, so the UI stays
    // stale until something else (e.g. focus) forces an update.
    static func == (lhs: Video, rhs: Video) -> Bool {
        lhs.stableId == rhs.stableId
            && lhs.name == rhs.name
            && lhs.views == rhs.views
            && lhs.duration == rhs.duration
            && lhs.publishedAt == rhs.publishedAt
            && lhs.createdAt == rhs.createdAt
            && lhs.thumbnailPath == rhs.thumbnailPath
            && lhs.previewPath == rhs.previewPath
            && lhs.commentReadHost == rhs.commentReadHost
            && lhs.channel?.displayName == rhs.channel?.displayName
            && lhs.channel?.host == rhs.channel?.host
            && lhs.channel?.avatars?.count == rhs.channel?.avatars?.count
            && lhs.channel?.avatars?.first?.fileUrl == rhs.channel?.avatars?.first?.fileUrl
            && lhs.account?.displayName == rhs.account?.displayName
            && lhs.account?.avatars?.first?.fileUrl == rhs.account?.avatars?.first?.fileUrl
    }

    /// Snapshot for anonymous history: rewrite thumbnail/preview/avatar paths to absolute URLs.
    func withHistoryImageURLs(mediaHost: String?, indexHost: String?, instanceBase: URL?) -> Video {
        func absolutePath(_ path: String?) -> String? {
            guard let path else { return nil }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                return trimmed
            }

            var hostPairs: [(federated: String?, cache: String?)] = []
            if let mediaHost, let indexHost, mediaHost.lowercased() != indexHost.lowercased() {
                hostPairs.append((indexHost, mediaHost))
            }
            if let mediaHost { hostPairs.append((mediaHost, mediaHost)) }
            if let indexHost { hostPairs.append((indexHost, indexHost)) }

            for pair in hostPairs {
                if let resolved = PeerTubeAssetURL.resolve(
                    path: trimmed,
                    instanceBase: instanceBase,
                    federatedHost: pair.federated,
                    cacheHost: pair.cache
                )?.absoluteString {
                    return resolved
                }
            }
            return trimmed
        }

        let resolvedAvatars: [ActorImage]? = {
            guard let avatars = channel?.avatars, !avatars.isEmpty else { return channel?.avatars }
            return avatars.map { image in
                let resolved = resolveAvatarURL(
                    image,
                    mediaHost: mediaHost,
                    indexHost: indexHost,
                    instanceBase: instanceBase
                )
                return ActorImage(
                    width: image.width,
                    height: image.height,
                    path: image.path,
                    fileUrl: resolved ?? image.fileUrl,
                    createdAt: image.createdAt,
                    updatedAt: image.updatedAt
                )
            }
        }()

        let updatedChannel: VideoChannelSummary? = {
            guard let channel else { return nil }
            return VideoChannelSummary(
                id: channel.id,
                name: channel.name,
                displayName: channel.displayName,
                url: channel.url,
                host: mediaHost ?? channel.host,
                avatars: resolvedAvatars
            )
        }()

        return Video(
            id: id,
            uuid: uuid,
            name: name,
            description: description,
            duration: duration,
            views: views,
            likes: likes,
            dislikes: dislikes,
            createdAt: createdAt,
            publishedAt: publishedAt,
            thumbnailPath: absolutePath(thumbnailPath),
            previewPath: absolutePath(previewPath),
            embedPath: embedPath,
            channel: updatedChannel,
            account: account,
            privacy: privacy,
            streamingPlaylists: streamingPlaylists,
            files: files,
            commentReadHost: indexHost ?? commentReadHost
        )
    }

    /// Preserves federated index host after API decode (decoder clears `commentReadHost`).
    func withCommentReadHost(_ host: String?) -> Video {
        let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return self }
        return Video(
            id: id,
            uuid: uuid,
            name: name,
            description: description,
            duration: duration,
            views: views,
            likes: likes,
            dislikes: dislikes,
            createdAt: createdAt,
            publishedAt: publishedAt,
            thumbnailPath: thumbnailPath,
            previewPath: previewPath,
            embedPath: embedPath,
            channel: channel,
            account: account,
            privacy: privacy,
            streamingPlaylists: streamingPlaylists,
            files: files,
            commentReadHost: trimmed
        )
    }

    /// Applies pre-resolved absolute URLs from anonymous history storage for grid display.
    func withDisplayImageLinks(_ links: AnonymousHistoryImageLinks) -> Video {
        let thumb = links.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = links.previewURL?.trimmingCharacters(in: .whitespacesAndNewlines)

        var updatedChannel = channel
        if let avatar = links.channelAvatarURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !avatar.isEmpty,
           let ch = channel {
            let avatarImage = ActorImage(
                width: nil,
                height: nil,
                path: nil,
                fileUrl: avatar,
                createdAt: nil,
                updatedAt: nil
            )
            updatedChannel = VideoChannelSummary(
                id: ch.id,
                name: ch.name,
                displayName: ch.displayName,
                url: ch.url,
                host: ch.host,
                avatars: [avatarImage]
            )
        }

        return Video(
            id: id,
            uuid: uuid,
            name: name,
            description: description,
            duration: duration,
            views: views,
            likes: likes,
            dislikes: dislikes,
            createdAt: createdAt,
            publishedAt: publishedAt,
            thumbnailPath: thumb.flatMap { $0.isEmpty ? nil : $0 } ?? thumbnailPath,
            previewPath: preview.flatMap { $0.isEmpty ? nil : $0 } ?? previewPath,
            embedPath: embedPath,
            channel: updatedChannel,
            account: account,
            privacy: privacy,
            streamingPlaylists: streamingPlaylists,
            files: files,
            commentReadHost: commentReadHost
        )
    }

    private func resolveAvatarURL(
        _ image: ActorImage,
        mediaHost: String?,
        indexHost: String?,
        instanceBase: URL?
    ) -> String? {
        if let fileUrl = image.fileUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fileUrl.isEmpty,
           fileUrl.hasPrefix("http://") || fileUrl.hasPrefix("https://") {
            return fileUrl
        }
        if let mediaHost, let indexHost {
            if let url = PeerTubeAssetURL.resolve(
                avatars: [image],
                instanceBase: instanceBase,
                federatedHost: indexHost,
                cacheHost: mediaHost
            )?.absoluteString {
                return url
            }
        }
        return PeerTubeAssetURL.resolve(
            avatars: [image],
            instanceBase: instanceBase,
            federatedHost: mediaHost ?? indexHost,
            cacheHost: mediaHost
        )?.absoluteString
    }

    /// Fills in view count, channel avatars, and/or thumbnail from an origin-instance detail fetch
    /// (fediverse-trending rows arrive from the hot API without view/avatar data, and with a
    /// thumbnail served only by the index host). Existing values are preserved when the enrichment
    /// doesn't supply a replacement.
    func withEnrichedMetadata(views newViews: Int?, avatars newAvatars: [ActorImage]?, thumbnailPath newThumbnail: String? = nil) -> Video {
        let resolvedViews = newViews ?? views
        let resolvedAvatars = (newAvatars?.isEmpty == false) ? newAvatars : channel?.avatars
        let trimmedThumbnail = newThumbnail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedThumbnail = (trimmedThumbnail?.isEmpty == false ? trimmedThumbnail : nil) ?? thumbnailPath
        let ch = channel
        let newChannel = VideoChannelSummary(
            id: ch?.id,
            name: ch?.name,
            displayName: ch?.displayName,
            url: ch?.url,
            host: ch?.host,
            avatars: resolvedAvatars
        )
        return Video(
            id: id,
            uuid: uuid,
            name: name,
            description: description,
            duration: duration,
            views: resolvedViews,
            likes: likes,
            dislikes: dislikes,
            createdAt: createdAt,
            publishedAt: publishedAt,
            thumbnailPath: resolvedThumbnail,
            previewPath: previewPath,
            embedPath: embedPath,
            channel: newChannel,
            account: account,
            privacy: privacy,
            streamingPlaylists: streamingPlaylists,
            files: files,
            commentReadHost: commentReadHost
        )
    }

    /// Fills in channel avatars (e.g. after loading plugin random-video rows that omit them).
    func withChannelAvatars(_ avatars: [ActorImage]) -> Video {
        let ch = channel
        let newChannel = VideoChannelSummary(
            id: ch?.id,
            name: ch?.name,
            displayName: ch?.displayName,
            url: ch?.url,
            host: ch?.host,
            avatars: avatars
        )
        return Video(
            id: id,
            uuid: uuid,
            name: name,
            description: description,
            duration: duration,
            views: views,
            likes: likes,
            dislikes: dislikes,
            createdAt: createdAt,
            publishedAt: publishedAt,
            thumbnailPath: thumbnailPath,
            previewPath: previewPath,
            embedPath: embedPath,
            channel: newChannel,
            account: account,
            privacy: privacy,
            streamingPlaylists: streamingPlaylists,
            files: files,
            commentReadHost: commentReadHost
        )
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

    /// Summary for diagnostics when playback URL resolution fails (no secrets).
    var playbackSourceSummary: String {
        let spCount = streamingPlaylists?.count ?? 0
        let first = streamingPlaylists?.first
        let hasPlaylistUrl = first?.playlistUrl != nil
        let hlsFileCount = first?.files?.count ?? 0
        let webFileCount = files?.count ?? 0
        let pid = privacy?.id.map(String.init) ?? "nil"
        return "streamingPlaylists=\(spCount) hasPlaylistUrl=\(hasPlaylistUrl) hlsFiles=\(hlsFileCount) webFiles=\(webFileCount) privacy=\(pid)"
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
        guard let dateStr = publishedAt ?? createdAt,
              let date = PeerTubeDate.parse(dateStr) else { return nil }
        return PeerTubeDate.relativeFull.localizedString(for: date, relativeTo: Date())
    }

    /// e.g. 1200 → "1.2K views", 2_500_000 → "2.5M views".
    var abbreviatedViewsLabel: String? {
        guard let v = views else { return nil }
        return "\(Self.abbreviateViewCount(v)) views"
    }

    private static func abbreviateViewCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return abbreviateUnit(Double(n) / 1_000_000.0, suffix: "M")
        }
        if n >= 1_000 {
            return abbreviateUnit(Double(n) / 1_000.0, suffix: "K")
        }
        return "\(n)"
    }

    private static func abbreviateUnit(_ value: Double, suffix: String) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return String(format: "%.0f%@", rounded.rounded(), suffix)
        }
        return String(format: "%.1f%@", rounded, suffix)
    }

    /// All available resolution options across HLS and web video files,
    /// sorted from highest to lowest resolution.
    var resolutionOptions: [ResolutionOption] {
        var options: [ResolutionOption] = []

        if let hlsFiles = streamingPlaylists?.first?.files {
            for file in hlsFiles {
                guard let resId = file.resolution?.id,
                      resId != Self.audioOnlyHLSResolutionId,
                      let label = file.resolution?.label,
                      let urlStr = file.playlistUrl ?? file.fileUrl,
                      let url = URL(string: urlStr) else { continue }
                options.append(ResolutionOption(
                    resolutionId: resId,
                    label: label,
                    url: url,
                    bytesPerSecond: bytesPerSecond(of: file)
                ))
            }
        }

        if options.isEmpty, let webFiles = files {
            for file in webFiles {
                guard let resId = file.resolution?.id,
                      let label = file.resolution?.label,
                      let urlStr = file.fileUrl,
                      let url = URL(string: urlStr) else { continue }
                options.append(ResolutionOption(
                    resolutionId: resId,
                    label: label,
                    url: url,
                    bytesPerSecond: bytesPerSecond(of: file)
                ))
            }
        }

        return options.sorted { ($0.resolutionId) > ($1.resolutionId) }
    }

    /// Average data rate of one rendition: its file size over the video's duration.
    private func bytesPerSecond(of file: VideoFile) -> Double? {
        guard let size = file.size, size > 0, let duration, duration > 0 else { return nil }
        return Double(size) / Double(duration)
    }

    /// PeerTube HLS: resolution `0` is audio-only; it must not be used as a video quality option.
    static let audioOnlyHLSResolutionId = 0
}

struct ResolutionOption: Identifiable {
    let resolutionId: Int
    let label: String
    let url: URL
    /// Average data rate of this rendition; `nil` when the server reports no file size or the
    /// video has no duration (live). Turns the Buffer cap setting from megabytes into seconds.
    var bytesPerSecond: Double? = nil
    var id: Int { resolutionId }
}

extension Array where Element == ResolutionOption {
    /// Data rate to size the forward buffer for. A fixed quality uses that rendition's rate;
    /// Auto can climb to the best one, so it is sized for the highest.
    func bufferBytesPerSecond(forQualityLabel label: String) -> Double? {
        if let fixed = first(where: { $0.label == label }) {
            return fixed.bytesPerSecond
        }
        return compactMap(\.bytesPerSecond).max()
    }
}

extension ResolutionOption {
    /// Hint for AVPlayer when playing the HLS master playlist (keeps the separate audio rendition).
    var preferredMaximumResolution: CGSize {
        Self.maximumResolutionSize(forId: resolutionId)
    }

    static func maximumResolutionSize(forId id: Int) -> CGSize {
        switch id {
        case 240: return CGSize(width: 426, height: 240)
        case 360: return CGSize(width: 640, height: 360)
        case 480: return CGSize(width: 854, height: 480)
        case 720: return CGSize(width: 1280, height: 720)
        case 1080: return CGSize(width: 1920, height: 1080)
        case 1440: return CGSize(width: 2560, height: 1440)
        case 2160: return CGSize(width: 3840, height: 2160)
        default: return CGSize(width: 1920, height: 1080)
        }
    }
}

enum HLSPlaybackPreferences {
    static func applyPreferredMaximumResolution(_ size: CGSize?, to item: AVPlayerItem) {
        if let size, size.width > 0, size.height > 0 {
            item.preferredMaximumResolution = size
        } else {
            item.preferredMaximumResolution = .zero
        }
    }
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
    let height: Int?
    let path: String?
    let fileUrl: String?
    let createdAt: String?
    let updatedAt: String?

    init(
        width: Int?,
        height: Int?,
        path: String?,
        fileUrl: String?,
        createdAt: String?,
        updatedAt: String?
    ) {
        self.width = width
        self.height = height
        self.path = path
        self.fileUrl = fileUrl
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Where to load the image from: the legacy instance-relative `path`, or the absolute
    /// `fileUrl` on servers that no longer send one (deprecated in PeerTube 8.0, null once the
    /// image is in object storage).
    var resolvablePath: String? {
        if let path, !path.isEmpty { return path }
        if let fileUrl, !fileUrl.isEmpty { return fileUrl }
        return nil
    }
}

/// One entry of the `thumbnails` array on videos and playlists (PeerTube 8.1 and later). The
/// fediverse hot API uses the same shape.
struct VideoThumbnail: Decodable {
    let width: Int?
    let height: Int?
    let fileUrl: String?
}

extension Array where Element == VideoThumbnail {
    /// Absolute URL of the narrowest or widest landscape entry. Square entries (podcast artwork)
    /// are used only when there is nothing else.
    func fileUrl(widest: Bool) -> String? {
        let usable = compactMap { thumbnail -> (width: Int, isLandscape: Bool, url: String)? in
            let url = thumbnail.fileUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else { return nil }
            let width = thumbnail.width ?? 0
            return (width, width > (thumbnail.height ?? 0), url)
        }
        let landscape = usable.filter { $0.isLandscape }
        let candidates = landscape.isEmpty ? usable : landscape
        let pick = widest
            ? candidates.max(by: { $0.width < $1.width })
            : candidates.min(by: { $0.width < $1.width })
        return pick?.url
    }
}

struct VideoPrivacy: Decodable {
    let id: Int?
    let label: String?
}

struct UserVideoRating: Decodable {
    let videoId: Int?
    let rating: String?
}

struct VideoFileTokenResponse: Decodable {
    let files: VideoFileTokenData
}

struct VideoFileTokenData: Decodable {
    let token: String
}

/// `GET /api/v1/videos/{id}/chapters` (PeerTube 6+).
struct VideoChapter: Decodable {
    /// Start time in seconds.
    let timecode: Double
    let title: String
}

struct VideoChaptersResponse: Decodable {
    let chapters: [VideoChapter]
}

extension Array where Element == VideoChapter {
    /// Index of the chapter playing at `time`: the last one starting at or before it.
    /// Expects the array sorted by `timecode`.
    func chapterIndex(at time: TimeInterval) -> Int? {
        lastIndex(where: { $0.timecode <= time })
    }

    func chapter(at time: TimeInterval) -> VideoChapter? {
        chapterIndex(at: time).map { self[$0] }
    }
}

/// Shared formatters for PeerTube's ISO 8601 timestamps; formatter creation is expensive and these
/// run inside grid tile bodies.
enum PeerTubeDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let relativeFull: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static let relativeAbbreviated: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? basic.date(from: string)
    }
}
