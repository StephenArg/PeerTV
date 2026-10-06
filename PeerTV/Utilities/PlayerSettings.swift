import Foundation

/// User-selectable playback buffer caps.
///
/// AVPlayer exposes only a *time-based* buffer hint (`AVPlayerItem.preferredForwardBufferDuration`),
/// not a byte-based one, so each MB / GB preset is converted to seconds at the data rate of what is
/// playing: the same cap holds fewer seconds of a 4K stream than of a 720p one. The rate comes from
/// the file size PeerTube reports for the rendition (see `ResolutionOption.bytesPerSecond`). AVPlayer
/// still treats the result as a hint and adapts around it.
enum BufferCap: Int, CaseIterable, Identifiable {
    case mb100 = 100
    case mb500 = 500
    case gb1 = 1024
    case gb2 = 2048
    case gb3 = 3072
    case gb5 = 5120
    case gb10 = 10240
    case gb15 = 15360

    /// Data rate assumed when the stream's real one isn't known: roughly 8 Mbps (≈ 1 MB/s).
    static let fallbackBytesPerSecond: Double = 1_000_000

    /// Smallest hint passed to AVPlayer, so a small cap on a very high bitrate stream still
    /// leaves it a workable buffer.
    static let minPreferredBufferSeconds: Double = 15

    /// Largest hint passed to AVPlayer, whatever the cap works out to. Left to itself, AVFoundation
    /// waits to fill a large buffer before resuming after a stall; the transport bar's stall
    /// recovery (`TransportBarController.tryResumeIfStalled`) is what starts playback as soon as
    /// a little data is loaded. If playback ever sits in "buffering" with data loaded, lower this.
    static let maxPreferredBufferSeconds: Double = 4 * 60 * 60

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

    /// Bytes this cap allows ahead of the playhead (raw values are megabytes).
    var bytes: Double { Double(rawValue) * 1_048_576 }

    /// Forward-buffer hint in seconds for a stream of the given data rate: how long this cap's
    /// bytes last at that rate. Pass `nil` when the rate isn't known.
    func preferredBufferSeconds(bytesPerSecond: Double?) -> Double {
        let rate = bytesPerSecond.flatMap { $0 > 0 ? $0 : nil } ?? Self.fallbackBytesPerSecond
        return min(max(bytes / rate, Self.minPreferredBufferSeconds), Self.maxPreferredBufferSeconds)
    }
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
    /// BCP-47 language id of the last selected caption track, or unset when captions are Off.
    static let preferredCaptionLanguageKey = "PeerTV.preferredCaptionLanguage"
    static let defaultPlaybackSpeedKey = "PeerTV.defaultPlaybackSpeed"

    /// Speeds offered by the player's Speed menu and the Default speed setting, fastest first.
    static let playbackSpeeds: [Float] = [3.0, 2.0, 1.5, 1.25, 1.0, 0.75, 0.5]

    /// Speed every video starts at (Settings → Playback). The player's Speed menu only changes the
    /// video being watched. Stored as a Double so the Settings `@AppStorage` can bind to it.
    static var defaultPlaybackSpeed: Float {
        let stored = UserDefaults.standard.double(forKey: defaultPlaybackSpeedKey)
        return stored > 0 ? Float(stored) : 1.0
    }

    /// "Normal" for 1x, otherwise e.g. "2x" or "1.25x".
    static func speedLabel(_ speed: Float) -> String {
        if speed == 1.0 { return "Normal" }
        if speed == Float(Int(speed)) { return "\(Int(speed))x" }
        return "\(speed)x"
    }

    static var preferredCaptionLanguage: String? {
        get {
            let s = UserDefaults.standard.string(forKey: preferredCaptionLanguageKey)
            return (s?.isEmpty == false) ? s : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: preferredCaptionLanguageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredCaptionLanguageKey)
            }
        }
    }

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
