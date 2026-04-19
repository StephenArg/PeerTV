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
