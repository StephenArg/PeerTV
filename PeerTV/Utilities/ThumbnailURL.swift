import Foundation

/// Resolves lazy-static paths and absolute URLs for thumbnails and avatars.
///
/// Uses `URL(relativeTo:)` so multi-segment paths (e.g. `lazy-static/thumbnails/…`)
/// resolve correctly. A single `appendingPathComponent` would encode `/` as `%2F`.
enum PeerTubeAssetURL {
    /// - Parameter federatedHost: Remote instance hostname (no scheme), e.g. plugin `instanceHost`, for relative paths on a federated origin.
    /// - Parameter cacheHost: Instance that mirrored the asset (e.g. comment list host); used when `path` is only valid there.
    static func resolve(path: String?, instanceBase: URL?, federatedHost: String? = nil, cacheHost: String? = nil) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://")
        || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let root: URL?
        if let h = cacheHost?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            root = URL(string: "https://\(h)/")
        } else if let h = federatedHost?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            root = URL(string: "https://\(h)/")
        } else {
            root = instanceBase
        }
        guard let root else { return nil }
        let relative = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return URL(string: relative, relativeTo: root)?.absoluteURL
    }

    /// Resolves an avatar from PeerTube comment/account payloads (prefers absolute `fileUrl` when present).
    static func resolve(
        avatars: [ActorImage]?,
        instanceBase: URL?,
        federatedHost: String? = nil,
        cacheHost: String? = nil
    ) -> URL? {
        guard let avatars, !avatars.isEmpty else { return nil }
        let pick = avatars.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }) ?? avatars[0]
        let pathURL = resolve(
            path: pick.path,
            instanceBase: instanceBase,
            federatedHost: federatedHost,
            cacheHost: cacheHost
        )
        if let fileUrl = trimmedNonEmpty(pick.fileUrl),
           fileUrl.hasPrefix("http://") || fileUrl.hasPrefix("https://"),
           let fileURL = URL(string: fileUrl) {
            if pathURL == nil || fileURLMatchesServingHost(fileURL, cacheHost: cacheHost, instanceBase: instanceBase) {
                return fileURL
            }
        }
        return pathURL
    }

    private static func fileURLMatchesServingHost(_ url: URL, cacheHost: String?, instanceBase: URL?) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let cache = cacheHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !cache.isEmpty, host == cache {
            return true
        }
        if let instance = instanceBase?.host?.lowercased(), host == instance {
            return true
        }
        return false
    }

    private static func trimmedNonEmpty(_ string: String?) -> String? {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension SessionStore {
    func thumbnailURL(path: String?) -> URL? {
        PeerTubeAssetURL.resolve(path: path, instanceBase: baseURL, federatedHost: nil)
    }
}
