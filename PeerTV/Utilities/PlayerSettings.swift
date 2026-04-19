import Foundation

/// User-selectable playback buffer caps.
///
/// AVPlayer exposes only a *time-based* buffer hint (`AVPlayerItem.preferredForwardBufferDuration`),
/// not a byte-based one, so we map each MB / GB preset to an equivalent number of seconds assuming
/// roughly 8 Mbps (≈ 1 MB/s). This is intentionally approximate — at lower bitrates the buffer will
/// cover more wall-clock time, at higher bitrates less. AVPlayer still adapts around this hint.
enum BufferCap: Int, CaseIterable, Identifiable {
    case mb100 = 100
    case mb500 = 500
    case gb1 = 1024
    case gb2 = 2048
    case gb3 = 3072
    case gb5 = 5120
    case gb10 = 10240
    case gb15 = 15360

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .mb100: return "100 MB"
        case .mb500: return "500 MB"
        case .gb1: return "1 GB"
        case .gb2: return "2 GB"
        case .gb3: return "3 GB"
        case .gb5: return "5 GB"
        case .gb10: return "10 GB"
        case .gb15: return "15 GB"
        }
    }

    /// Forward-buffer hint in seconds (MB value × 1 s at the 8 Mbps reference bitrate).
    var preferredBufferSeconds: Double { Double(rawValue) }
}

/// User-selectable default playback quality. Matches PeerTube's standard resolution ids
/// (the vertical pixel count). `auto` lets AVFoundation's adaptive HLS do the selection.
enum DefaultResolution: Int, CaseIterable, Identifiable {
    case auto = 0
    case p240 = 240
    case p360 = 360
    case p480 = 480
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .p240: return "240p"
        case .p360: return "360p"
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p (HD)"
        case .p1440: return "1440p (2K)"
        case .p2160: return "2160p (4K)"
        }
    }
}

/// Persistent playback settings stored in `UserDefaults`.
enum PlayerSettings {
    static let bufferCapKey = "PeerTV.bufferCapMB"
    static let defaultResolutionKey = "PeerTV.defaultResolutionId"

    /// Selected buffer cap. Defaults to 1 GB the first time the app launches.
    static var bufferCap: BufferCap {
        get {
            let raw = UserDefaults.standard.integer(forKey: bufferCapKey)
            return BufferCap(rawValue: raw) ?? .gb1
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: bufferCapKey)
        }
    }

    /// Preferred default resolution. Defaults to `.auto`. If the chosen resolution isn't
    /// available for a given video, the player falls back to the next lower resolution it
    /// does have, and if none exist, back to Auto (adaptive HLS).
    static var defaultResolution: DefaultResolution {
        get {
            // A missing key returns 0 from `.integer(forKey:)`, which matches `.auto`.
            let raw = UserDefaults.standard.integer(forKey: defaultResolutionKey)
            return DefaultResolution(rawValue: raw) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultResolutionKey)
        }
    }
}
