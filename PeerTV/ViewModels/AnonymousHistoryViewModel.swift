import Foundation
import Combine

@MainActor
final class AnonymousHistoryViewModel: ObservableObject {
    @Published var videos: [Video] = []
    @Published var originHostByVideoId: [String: String] = [:]
    @Published var commentReadHostByVideoId: [String: String] = [:]
    @Published var thumbnailURLByVideoId: [String: URL] = [:]
    @Published var avatarURLByVideoId: [String: URL] = [:]

    private var storeCancellable: AnyCancellable?

    func bind(to store: AnonymousHistoryStore = .shared) {
        storeCancellable?.cancel()
        storeCancellable = store.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.apply(entries: entries)
            }
        apply(entries: store.entries)
    }

    private func apply(entries: [AnonymousHistoryEntry]) {
        videos = entries.map(\.video)
        var origins: [String: String] = [:]
        var commentHosts: [String: String] = [:]
        var thumbnails: [String: URL] = [:]
        var avatars: [String: URL] = [:]

        for entry in entries {
            if let host = entry.originHost {
                origins[entry.videoId] = host
            }
            if let host = entry.commentReadHost {
                commentHosts[entry.videoId] = host
            }
            if let url = Self.thumbnailURL(for: entry) {
                thumbnails[entry.videoId] = url
            }
            if let url = Self.avatarURL(for: entry) {
                avatars[entry.videoId] = url
            }
        }

        originHostByVideoId = origins
        commentReadHostByVideoId = commentHosts
        thumbnailURLByVideoId = thumbnails
        avatarURLByVideoId = avatars
    }

    private static func thumbnailURL(for entry: AnonymousHistoryEntry) -> URL? {
        if let urlString = entry.imageLinks.thumbnailURL,
           let url = URL(string: urlString) {
            return url
        }
        return resolvedAssetURL(
            path: entry.video.thumbnailPath,
            mediaHost: entry.originHost,
            indexHost: entry.commentReadHost
        )
    }

    private static func avatarURL(for entry: AnonymousHistoryEntry) -> URL? {
        if let urlString = entry.imageLinks.channelAvatarURL,
           let url = URL(string: urlString) {
            return url
        }
        return PeerTubeAssetURL.resolve(
            avatars: entry.video.channel?.avatars ?? entry.video.account?.avatars,
            instanceBase: nil,
            federatedHost: entry.commentReadHost,
            cacheHost: entry.originHost
        )
    }

    private static func resolvedAssetURL(path: String?, mediaHost: String?, indexHost: String?) -> URL? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return PeerTubeAssetURL.resolve(
            path: trimmed,
            instanceBase: nil,
            federatedHost: indexHost,
            cacheHost: mediaHost
        )
    }
}
