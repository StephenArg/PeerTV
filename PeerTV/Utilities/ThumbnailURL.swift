import Foundation

/// Resolves lazy-static paths and absolute URLs for thumbnails and avatars.
///
/// Uses `URL(relativeTo:)` so multi-segment paths (e.g. `lazy-static/thumbnails/…`)
/// resolve correctly. A single `appendingPathComponent` would encode `/` as `%2F`.
enum PeerTubeAssetURL {
    /// - Parameter federatedHost: Remote instance hostname (no scheme), e.g. plugin `instanceHost`, for relative paths on a federated origin.
    static func resolve(path: String?, instanceBase: URL?, federatedHost: String? = nil) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let root: URL?
        if let h = federatedHost?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            root = URL(string: "https://\(h)/")
        } else {
            root = instanceBase
        }
        guard let root else { return nil }
        let relative = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return URL(string: relative, relativeTo: root)?.absoluteURL
    }
}

extension SessionStore {
    func thumbnailURL(path: String?) -> URL? {
        PeerTubeAssetURL.resolve(path: path, instanceBase: baseURL, federatedHost: nil)
    }
}
