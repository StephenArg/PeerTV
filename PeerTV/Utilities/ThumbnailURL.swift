import Foundation

/// Resolves a relative thumbnail/avatar path against the instance base URL.
/// If the path is already a full URL, returns it directly.
extension SessionStore {
    func thumbnailURL(path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        guard let base = baseURL else { return nil }
        return base.appendingPathComponent(path)
    }
}
