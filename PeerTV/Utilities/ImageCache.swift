import SwiftUI

/// Lightweight in-memory image cache backed by NSCache.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
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

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
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

        let key = url.absoluteString
        if let cached = ImageCache.shared.image(for: key) {
            uiImage = cached
            return
        }

        // No `isLoading` guard: `.task(id: url)` already guarantees a single task per URL, and a
        // guard shared across cancelled/replacement tasks can race so the new URL's load is skipped
        // (e.g. when an enriched thumbnail URL replaces the original one).
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            if let img = UIImage(data: data) {
                ImageCache.shared.setImage(img, for: key)
                uiImage = img
            }
        } catch {
            // Silently fail (including cancellation when the URL is superseded); placeholder stays.
        }
    }
}
