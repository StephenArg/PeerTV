import Foundation
import Combine

/// Cached image URLs stored with each anonymous history row.
struct AnonymousHistoryImageLinks: Equatable, Hashable {
    var thumbnailURL: String?
    var previewURL: String?
    var channelAvatarURL: String?

    static func fromSnapshot(_ video: Video, mediaHost: String?, indexHost: String?) -> AnonymousHistoryImageLinks {
        func absolute(_ stored: String?) -> String? {
            guard let stored else { return nil }
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    instanceBase: nil,
                    federatedHost: pair.federated,
                    cacheHost: pair.cache
                )?.absoluteString {
                    return resolved
                }
            }
            return trimmed
        }

        let avatarURL = video.channel?.avatars?.compactMap(\.fileUrl).first
            ?? video.account?.avatars?.compactMap(\.fileUrl).first

        return AnonymousHistoryImageLinks(
            thumbnailURL: absolute(video.thumbnailPath),
            previewURL: absolute(video.previewPath),
            channelAvatarURL: absolute(avatarURL)
        )
    }
}

/// Tile image URLs captured when playback starts (exact URLs shown on the grid card).
struct AnonymousHistoryTileSnapshot: Equatable {
    var thumbnailURL: String?
    var channelAvatarURL: String?
}

/// Session-scoped watch history for anonymous browsing (in-memory only).
@MainActor
final class AnonymousHistoryStore: ObservableObject {
    static let shared = AnonymousHistoryStore()

    @Published private(set) var entries: [AnonymousHistoryEntry] = []

    private(set) var isActive = false
    private var stagedTileSnapshots: [String: AnonymousHistoryTileSnapshot] = [:]

    private init() {}

    func activate() {
        isActive = true
    }

    func deactivate(clearEntries: Bool) {
        isActive = false
        stagedTileSnapshots = [:]
        if clearEntries {
            entries = []
        }
    }

    /// Call when opening the player so history can reuse the tile's preview URLs later.
    func stageTileSnapshot(
        videoId: String,
        thumbnailURL: URL?,
        channelAvatarURL: URL?
    ) {
        guard isActive else { return }
        stagedTileSnapshots[videoId] = AnonymousHistoryTileSnapshot(
            thumbnailURL: thumbnailURL?.absoluteString,
            channelAvatarURL: channelAvatarURL?.absoluteString
        )
    }

    /// Re-applies staged tile URLs when the player closes (covers enter + exit timing).
    func finalizeTileSnapshot(for videoId: String) {
        guard isActive, let staged = stagedTileSnapshots.removeValue(forKey: videoId) else { return }
        guard let idx = entries.firstIndex(where: { $0.videoId == videoId }) else { return }
        applyTileSnapshot(staged, toEntryAt: idx)
    }

    func record(video: Video, apiHosts: [String] = []) {
        guard isActive else { return }
        let id = video.stableId
        let (mediaHost, indexHost) = Self.assetHosts(for: video, apiHosts: apiHosts)
        let staged = stagedTileSnapshots[id]

        var source = video
        if source.commentReadHost == nil, let indexHost {
            source = source.withCommentReadHost(indexHost)
        }

        let imageLinks: AnonymousHistoryImageLinks
        let displayVideo: Video

        if let staged, staged.thumbnailURL != nil || staged.channelAvatarURL != nil {
            imageLinks = AnonymousHistoryImageLinks(
                thumbnailURL: staged.thumbnailURL,
                previewURL: nil,
                channelAvatarURL: staged.channelAvatarURL
            )
            displayVideo = source.withDisplayImageLinks(imageLinks)
        } else {
            let snapshot = source.withHistoryImageURLs(
                mediaHost: mediaHost,
                indexHost: indexHost,
                instanceBase: nil
            )
            imageLinks = AnonymousHistoryImageLinks.fromSnapshot(
                snapshot,
                mediaHost: mediaHost,
                indexHost: indexHost
            )
            displayVideo = snapshot.withDisplayImageLinks(imageLinks)
        }

        if let idx = entries.firstIndex(where: { $0.videoId == id }) {
            var row = entries[idx]
            row.watchedAt = Date()
            row.video = displayVideo
            row.imageLinks = imageLinks
            row.originHost = mediaHost ?? row.originHost
            row.commentReadHost = indexHost ?? row.commentReadHost
            entries.remove(at: idx)
            entries.insert(row, at: 0)
            return
        }

        let entry = AnonymousHistoryEntry(
            videoId: id,
            watchedAt: Date(),
            video: displayVideo,
            imageLinks: imageLinks,
            originHost: mediaHost,
            commentReadHost: indexHost
        )
        entries.insert(entry, at: 0)
    }

    /// Media host serves thumbnails; index host (e.g. peertube.watch) is for comments only.
    private static func assetHosts(for video: Video, apiHosts: [String]) -> (media: String?, index: String?) {
        let hosts = normalizedHosts(from: apiHosts.isEmpty ? video.federatedAPIHosts : apiHosts)

        if hosts.count >= 2 {
            return (hosts[1], hosts[0])
        }

        let index = normalizedHost(video.commentReadHost) ?? hosts.first
        let media = normalizedHost(video.channel?.host)
            ?? normalizedHost(video.originHost)
            ?? hosts.last

        return (media, index)
    }

    private static func normalizedHosts(from raw: [String]) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for item in raw {
            guard let host = normalizedHost(item) else { continue }
            let key = host.lowercased()
            guard seen.insert(key).inserted else { continue }
            hosts.append(host)
        }
        return hosts
    }

    private static func normalizedHost(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyTileSnapshot(_ staged: AnonymousHistoryTileSnapshot, toEntryAt index: Int) {
        guard entries.indices.contains(index) else { return }
        var row = entries[index]
        var links = row.imageLinks
        if let thumb = staged.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines), !thumb.isEmpty {
            links.thumbnailURL = thumb
        }
        if let avatar = staged.channelAvatarURL?.trimmingCharacters(in: .whitespacesAndNewlines), !avatar.isEmpty {
            links.channelAvatarURL = avatar
        }
        row.imageLinks = links
        row.video = row.video.withDisplayImageLinks(links)
        entries[index] = row
    }
}

struct AnonymousHistoryEntry: Identifiable, Hashable {
    var id: String { videoId }
    let videoId: String
    var watchedAt: Date
    var video: Video
    var imageLinks: AnonymousHistoryImageLinks
    var originHost: String?
    var commentReadHost: String?
}
