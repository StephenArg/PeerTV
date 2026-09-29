import SwiftUI

/// In-memory cache of decoded images, plus a loader that shares one request per URL.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    @MainActor private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 128 * 1024 * 1024

        let config = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ImageURLCache", isDirectory: true)
        config.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            directory: directory
        )
        session = URLSession(configuration: config)
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }

    /// Returns the decoded image for `url`, fetching it if needed. Concurrent callers for the same
    /// URL share one request. The fetch is not cancelled when a caller goes away, so a tile scrolled
    /// past still warms the cache for when it comes back.
    @MainActor
    func load(_ url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = image(for: key) { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task.detached(priority: .userInitiated) { [session] () -> UIImage? in
            guard let (data, response) = try? await session.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let image = UIImage(data: data) else { return nil }
            // Decode now, off the main thread, instead of on first draw during scrolling.
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { setImage(image, for: key) }
        return image
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}

/// SwiftUI view that loads a remote image with caching.
struct CachedAsyncImage: View {
    let url: URL?
    var placeholder: AnyView = AnyView(
        ZStack {
            Color.gray.opacity(0.15)
            Image(systemName: "film")
                .font(.system(size: 90))
                .foregroundStyle(.gray.opacity(0.5))
        }
    )

    @State private var uiImage: UIImage?

    /// Checks the memory cache synchronously so a recycled grid tile shows its image on the first
    /// frame instead of flashing the placeholder until `.task` runs.
    private var displayedImage: UIImage? {
        if let url, let cached = ImageCache.shared.image(for: url.absoluteString) {
            return cached
        }
        return uiImage
    }

    var body: some View {
        Group {
            if let displayedImage {
                Image(uiImage: displayedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else { return }
        // No `isLoading` guard: `.task(id: url)` already guarantees a single task per URL, and a
        // guard shared across cancelled/replacement tasks can race so the new URL's load is skipped
        // (e.g. when an enriched thumbnail URL replaces the original one).
        let loaded = await ImageCache.shared.load(url)
        guard !Task.isCancelled, let loaded else { return }
        uiImage = loaded
    }
}
