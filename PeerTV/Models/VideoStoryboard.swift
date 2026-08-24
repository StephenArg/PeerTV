import UIKit

/// PeerTube sprite-sheet thumbnail metadata. A storyboard image contains a grid of equally-sized
/// thumbnails laid out left-to-right, top-to-bottom, one thumbnail every `spriteDuration` seconds
/// of source video. Served by the instance at `/lazy-static/storyboards/…` (or similar).
struct VideoStoryboard: Decodable, Hashable {
    /// Relative path the instance serves the sprite-sheet image from, e.g.
    /// `/lazy-static/storyboards/<uuid>.jpg`. Must be resolved against the instance's base URL.
    let storyboardPath: String
    let totalHeight: Int
    let totalWidth: Int
    let spriteHeight: Int
    let spriteWidth: Int
    /// Seconds of source video between consecutive sprites (usually 1…10).
    let spriteDuration: Int
}

struct VideoStoryboardsResponse: Decodable {
    let storyboards: [VideoStoryboard]
}

/// Converts a time (seconds) into the matching sprite cropped from the downloaded sheet.
/// Immutable, trivially Sendable — one instance is created after the sheet finishes downloading.
struct StoryboardThumbnailProvider {
    let sheet: UIImage
    let storyboard: VideoStoryboard

    private var columns: Int {
        max(1, storyboard.totalWidth / max(1, storyboard.spriteWidth))
    }

    private var rows: Int {
        max(1, storyboard.totalHeight / max(1, storyboard.spriteHeight))
    }

    private var totalSprites: Int { columns * rows }

    func image(for time: TimeInterval) -> UIImage? {
        guard time.isFinite, time >= 0 else { return nil }
        guard storyboard.spriteDuration > 0 else { return nil }
        guard let cgImage = sheet.cgImage else { return nil }

        let idx = min(max(0, Int(time / Double(storyboard.spriteDuration))), totalSprites - 1)
        let col = idx % columns
        let row = idx / columns

        // cgImage uses pixel coordinates; `UIImage.scale` lets us map UI points to pixels
        // if the asset was loaded at a non-1 scale.
        let scale = sheet.scale
        let rect = CGRect(
            x: CGFloat(col * storyboard.spriteWidth) * scale,
            y: CGFloat(row * storyboard.spriteHeight) * scale,
            width: CGFloat(storyboard.spriteWidth) * scale,
            height: CGFloat(storyboard.spriteHeight) * scale
        )
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: sheet.imageOrientation)
    }
}

// MARK: - Tile preview settings

/// User preference for showing resume progress bars on video thumbnails.
enum ThumbnailProgressBarSettings {
    private static let visibleKey = "PeerTV.showThumbnailProgressBars"

    /// Whether partially watched videos show a progress bar on their thumbnail. Defaults to true.
    static var isVisible: Bool {
        get {
            if UserDefaults.standard.object(forKey: visibleKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: visibleKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: visibleKey)
        }
    }
}

/// User preference for cycling storyboard preview frames on a focused video tile.
enum TilePreviewSettings {
    private static let enabledKey = "PeerTV.tilePreviewEnabled"

    /// Whether focused video tiles cycle through storyboard preview frames. Defaults to true.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}

// MARK: - Tile storyboard loader

private final class StoryboardProviderBox {
    let provider: StoryboardThumbnailProvider
    init(_ provider: StoryboardThumbnailProvider) { self.provider = provider }
}

/// Loads and caches `StoryboardThumbnailProvider`s for grid tiles so a focused tile can
/// cycle through preview frames (the same sprite sheets used for scrubbing in the player).
/// Loads are triggered on focus, deduplicated, and cached in memory.
@MainActor
final class TileStoryboardLoader {
    static let shared = TileStoryboardLoader()

    private let cache = NSCache<NSString, StoryboardProviderBox>()
    /// Videos that returned no storyboard, so we don't refetch them this session.
    private var unavailable: Set<String> = []
    private var inFlight: [String: Task<StoryboardThumbnailProvider?, Never>] = [:]

    private init() {
        cache.countLimit = 40
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedProvider(for videoId: String) -> StoryboardThumbnailProvider? {
        cache.object(forKey: videoId as NSString)?.provider
    }

    /// Returns a sprite provider for the video, fetching and caching it if needed.
    /// Network failures are not cached (allowing a retry on the next focus); a definitive
    /// "no storyboard" response is cached so we stop trying.
    func provider(
        for video: Video,
        instanceClient: PeerTubeAPIClient,
        federatedDisplay: Bool
    ) async -> StoryboardThumbnailProvider? {
        let id = video.stableId
        if let cached = cachedProvider(for: id) { return cached }
        if unavailable.contains(id) { return nil }
        if let task = inFlight[id] { return await task.value }

        let task = Task { [weak self] () -> StoryboardThumbnailProvider? in
            guard let self else { return nil }
            do {
                let provider = try await self.loadProvider(
                    video: video,
                    instanceClient: instanceClient,
                    federatedDisplay: federatedDisplay
                )
                if let provider {
                    let cost = Self.estimatedCost(for: provider.sheet)
                    self.cache.setObject(StoryboardProviderBox(provider), forKey: id as NSString, cost: cost)
                } else {
                    self.unavailable.insert(id)
                }
                return provider
            } catch {
                // Transient error — leave uncached so a later focus can retry.
                return nil
            }
        }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        return result
    }

    private func loadProvider(
        video: Video,
        instanceClient: PeerTubeAPIClient,
        federatedDisplay: Bool
    ) async throws -> StoryboardThumbnailProvider? {
        let clients: [PeerTubeAPIClient]
        if federatedDisplay {
            let hosts = video.federatedAPIHosts
            clients = hosts.isEmpty ? [instanceClient] : hosts.map { PeerTubeOriginClients.publicClient(forHost: $0) }
        } else {
            clients = [instanceClient]
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var sawDefinitiveEmpty = false
        var lastError: Error?
        for client in clients {
            do {
                let metadata = try await client.rawRequest(.videoStoryboards(id: video.stableId))
                let response = try decoder.decode(VideoStoryboardsResponse.self, from: metadata)
                guard let storyboard = response.storyboards.first,
                      let url = sheetURL(path: storyboard.storyboardPath, base: client.baseURL)
                else {
                    sawDefinitiveEmpty = true
                    continue
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let sheet = UIImage(data: data) else {
                    sawDefinitiveEmpty = true
                    continue
                }
                return StoryboardThumbnailProvider(sheet: sheet, storyboard: storyboard)
            } catch {
                lastError = error
                continue
            }
        }

        if sawDefinitiveEmpty { return nil }
        if let lastError { throw lastError }
        return nil
    }

    private func sheetURL(path: String, base: URL?) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        guard let base else { return nil }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    private static func estimatedCost(for image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}
