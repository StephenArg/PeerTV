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
    @State private var isLoading = false

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
        guard let url, !isLoading else { return }

        let key = url.absoluteString
        if let cached = ImageCache.shared.image(for: key) {
            uiImage = cached
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                ImageCache.shared.setImage(img, for: key)
                uiImage = img
            }
        } catch {
            // Silently fail; placeholder stays.
        }
    }
}
