import UIKit
import AVKit
import SwiftUI
import os

private enum PlaybackLog {
    static let log = Logger(subsystem: "com.peernext.PeerTV", category: "Playback")

    static func describe(url: URL) -> String {
        let path = url.path
        let pathPreview = path.count > 120 ? String(path.prefix(120)) + "…" : path
        return "\(url.scheme ?? "https")://\(url.host ?? "?")\(pathPreview)"
    }
}

// MARK: - Playlist playback queue

/// When playing from a playlist, carries ordered video ids and whether to advance when an item ends.
struct PlaylistPlaybackQueue {
    let videoIds: [String]
    let currentIndex: Int
    let autoplayEnabled: Bool
    let apiClient: PeerTubeAPIClient
    let accessToken: String?
}

/// Detail, stream URL (with any video file token applied), and asset for a playlist item,
/// ready to wrap in a new `AVPlayerItem`.
private struct PreparedPlaylistItem {
    let video: Video
    let url: URL
    let asset: AVURLAsset
}

private struct PlaylistItemPrefetch {
    let videoId: String
    let startedAt: Date
    let task: Task<PreparedPlaylistItem?, Never>

    /// The prefetched URL may carry a video file token; past this age (e.g. the user paused
    /// near the end) it's prepared afresh instead.
    var isStale: Bool { Date().timeIntervalSince(startedAt) > 5 * 60 }
}

// MARK: - Now Playing metadata

/// Title, channel, and artwork published through `AVPlayerItem.externalMetadata`, which AVKit
/// forwards to the system Now Playing info (Control Center).
struct NowPlayingMetadata {
    let title: String
    let subtitle: String?
    let artworkURL: URL?

    init(title: String, subtitle: String?, artworkURL: URL?) {
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
    }

    /// `preferredArtworkURL` is usually the tile thumbnail the user just selected, which is
    /// already in `ImageCache`; otherwise the larger preview image is resolved on `apiBaseURL`.
    init(video: Video, apiBaseURL: URL?, preferredArtworkURL: URL? = nil) {
        title = video.name ?? ""
        subtitle = video.channel?.displayName ?? video.account?.displayName
        artworkURL = preferredArtworkURL
            ?? PeerTubeAssetURL.resolve(path: video.previewPath ?? video.thumbnailPath, instanceBase: apiBaseURL)
    }

    func metadataItems(artwork: UIImage?) -> [AVMetadataItem] {
        var items = [Self.textItem(.commonIdentifierTitle, title)]
        if let subtitle, !subtitle.isEmpty {
            items.append(Self.textItem(.iTunesMetadataTrackSubTitle, subtitle))
        }
        if let data = artwork?.jpegData(compressionQuality: 0.85) {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.value = data as NSData
            item.dataType = kCMMetadataBaseDataType_JPEG as String
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        return items
    }

    private static func textItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

// MARK: - PlayerPresenter

/// Presents AVPlayerViewController directly via UIKit — no SwiftUI fullScreenCover
/// in between. This eliminates the double-transition flash and double-back-press issue.
@MainActor
final class PlayerPresenter {
    static let shared = PlayerPresenter()

    private var isPresenting = false
    private var loadingOverlay: UIView?
    /// Full-screen player dismissed into Picture in Picture. Retained so playback,
    /// progress reporting, and restore survive without a presented controller.
    private var pictureInPictureSession: (coordinator: PlayerCoordinator, container: PlayerContainerViewController)?

    func play(
        videoId: String,
        apiClient: PeerTubeAPIClient,
        accessToken: String?,
        apiHosts: [String]? = nil,
        accountId: UUID? = nil,
        playlistQueue: PlaylistPlaybackQueue? = nil,
        historyTileThumbnailURL: URL? = nil,
        historyTileChannelAvatarURL: URL? = nil
    ) {
        if let session = pictureInPictureSession {
            pictureInPictureSession = nil
            session.coordinator.stopPictureInPictureAndCleanup()
        }
        guard !isPresenting else { return }
        isPresenting = true

        if AnonymousHistoryStore.shared.isActive {
            AnonymousHistoryStore.shared.stageTileSnapshot(
                videoId: videoId,
                thumbnailURL: historyTileThumbnailURL,
                channelAvatarURL: historyTileChannelAvatarURL
            )
        }

        guard let window = Self.keyWindow else {
            PlaybackLog.log.error("play aborted: no key window videoId=\(videoId, privacy: .public)")
            isPresenting = false
            return
        }

        if let localURL = DownloadManager.shared.localFileURL(for: videoId) {
            let localEntry = DownloadManager.shared.downloadedVideos.first(where: { $0.videoId == videoId })
            let localTitle = localEntry?.name ?? ""
            let prefetch = DownloadManager.shared.localPeerTubeCaptions(for: videoId)
            // Local downloads have no resolution choice; play the file as-is.
            let localDuration = localEntry?.duration
            let localNowPlaying = NowPlayingMetadata(
                title: localTitle,
                subtitle: localEntry?.channelName,
                artworkURL: historyTileThumbnailURL
                    ?? PeerTubeAssetURL.resolve(path: localEntry?.thumbnailPath, instanceBase: apiClient.baseURL)
            )
            presentPlayer(
                url: localURL,
                autoURL: localURL,
                initialLabel: "Auto",
                resolutions: [],
                accessToken: nil,
                videoId: videoId,
                title: localTitle,
                apiClient: apiClient,
                playlistQueue: playlistQueue,
                isLocalDownload: true,
                accountId: accountId,
                prefetchedCaptions: prefetch.isEmpty ? nil : prefetch,
                durationSeconds: localDuration,
                nowPlaying: localNowPlaying
            )
            return
        }

        showLoadingOverlay(on: window)
        PlaybackLog.log.notice("loading video detail videoId=\(videoId, privacy: .public)")

        Task {
            do {
                let data: Data
                let resolvedClient: PeerTubeAPIClient
                if let apiHosts, !apiHosts.isEmpty {
                    (data, resolvedClient) = try await PeerTubeOriginClients.fetchVideoDetail(
                        videoId: videoId,
                        hosts: apiHosts
                    )
                } else {
                    data = try await apiClient.rawRequest(.videoDetail(id: videoId))
                    resolvedClient = apiClient
                }
                PlaybackLog.log.notice("videoDetail OK bytes=\(data.count) videoId=\(videoId, privacy: .public)")
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                decoder.dateDecodingStrategy = .iso8601
                let video = try decoder.decode(Video.self, from: data)

                if AnonymousHistoryStore.shared.isActive {
                    AnonymousHistoryStore.shared.record(
                        video: video,
                        apiHosts: apiHosts ?? []
                    )
                }

                guard let url = video.hlsPlaylistURL ?? video.playbackURL else {
                    PlaybackLog.log.error("no playback URL videoId=\(videoId, privacy: .public) \(video.playbackSourceSummary, privacy: .public)")
                    removeLoadingOverlay()
                    isPresenting = false
                    Self.presentPlaybackAlert(
                        title: "Couldn’t play video",
                        message: "No streaming files were found for this video."
                    )
                    return
                }

                let chosen = video.hlsPlaylistURL != nil ? "hlsPlaylist" : "fallback"
                let isPrivatePath = url.path.contains("/private/")
                PlaybackLog.log.notice("starting playback videoId=\(videoId, privacy: .public) source=\(chosen, privacy: .public) privatePath=\(isPrivatePath) url=\(Self.describePlaybackURL(url), privacy: .public) hasToken=\(accessToken != nil)")

                let playURL = await Self.urlWithHLSTokenIfNeeded(
                    url: url,
                    videoId: videoId,
                    apiClient: resolvedClient,
                    accessToken: accessToken
                )

                removeLoadingOverlay()
                // Honor the user's default-resolution setting before handing the URL to the
                // coordinator; the AVPlayerItem starts on that variant instead of the master.
                let resolutionOptions = video.resolutionOptions
                let pick = Self.chooseInitialPlayback(
                    resolutions: resolutionOptions,
                    masterURL: playURL,
                    defaultResolution: PlayerSettings.defaultResolution
                )

                presentPlayer(
                    url: playURL,
                    autoURL: playURL,
                    initialLabel: pick.label,
                    preferredMaximumResolution: pick.preferredMaximumResolution,
                    resolutions: resolutionOptions,
                    accessToken: accessToken,
                    videoId: videoId,
                    numericVideoId: video.id,
                    title: video.name ?? "",
                    apiClient: resolvedClient,
                    playlistQueue: playlistQueue,
                    isLocalDownload: false,
                    accountId: accountId,
                    durationSeconds: video.duration,
                    nowPlaying: NowPlayingMetadata(
                        video: video,
                        apiBaseURL: resolvedClient.baseURL,
                        preferredArtworkURL: historyTileThumbnailURL
                    )
                )
            } catch {
                PlaybackLog.log.error("videoDetail failed videoId=\(videoId, privacy: .public) \(error.localizedDescription, privacy: .public) \(String(describing: error), privacy: .public)")
                removeLoadingOverlay()
                isPresenting = false
                Self.presentPlaybackAlert(
                    title: "Couldn’t load video",
                    message: error.localizedDescription
                )
            }
        }
    }

    private static func describePlaybackURL(_ url: URL) -> String {
        PlaybackLog.describe(url: url)
    }

    /// Private HLS needs `reinjectVideoFileToken`. Logged-in playback from object storage/CDN (cross-origin)
    /// needs `videoFileToken` on the query — same idea as `DownloadManager` for direct files — and must not
    /// rely on `Authorization: Bearer` to the storage host (S3 rejects it).
    fileprivate static func urlWithHLSTokenIfNeeded(
        url: URL,
        videoId: String,
        apiClient: PeerTubeAPIClient,
        accessToken: String?
    ) async -> URL {
        guard url.pathExtension.lowercased() == "m3u8" else { return url }
        let isPrivate = url.path.contains("/private/")
        let instanceHost = await MainActor.run { apiClient.baseURL?.host?.lowercased() }
        let playbackHost = url.host?.lowercased()
        let isCrossOrigin: Bool = {
            if let ih = instanceHost, let ph = playbackHost {
                return ih != ph
            }
            return playbackHost != nil
        }()
        let isLoggedIn = accessToken.map { !$0.isEmpty } ?? false

        let shouldFetchToken = isPrivate || (isLoggedIn && isCrossOrigin)
        guard shouldFetchToken else { return url }

        do {
            let resp: VideoFileTokenResponse = try await apiClient.request(.videoFileToken(id: videoId))
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "videoFileToken", value: resp.files.token))
            if isPrivate {
                items.append(URLQueryItem(name: "reinjectVideoFileToken", value: "true"))
            }
            components.queryItems = items
            if let withToken = components.url {
                let label = isPrivate ? "private HLS" : "cross-origin HLS"
                PlaybackLog.log.notice("\(label, privacy: .public): applied videoFileToken query videoId=\(videoId, privacy: .public)")
                return withToken
            }
        } catch {
            PlaybackLog.log.error("videoFileToken failed videoId=\(videoId, privacy: .public) \(error.localizedDescription, privacy: .public) — continuing with manifest URL")
        }
        return url
    }

    /// Presents a simple alert from the topmost view controller (works before/after player is shown).
    private static func presentPlaybackAlert(title: String, message: String) {
        guard let root = Self.keyWindow?.rootViewController else {
            PlaybackLog.log.error("presentPlaybackAlert: no root VC")
            return
        }
        let top = Self.topViewController(from: root)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }

    /// Chooses startup URL and quality label from the user's default-resolution setting.
    ///
    /// For HLS (`masterURL` is `.m3u8`), always returns the **master** playlist URL. PeerTube
    /// per-resolution `playlistUrl` values are often video-only; audio is linked from the master.
    /// `preferredMaximumResolution` steers AVPlayer to the intended rung without dropping audio.
    ///
    /// For progressive (non-HLS) files, returns the matching file URL directly.
    static func chooseInitialPlayback(
        resolutions: [ResolutionOption],
        masterURL: URL,
        defaultResolution: DefaultResolution
    ) -> (url: URL, label: String, preferredMaximumResolution: CGSize?) {
        let isHLSMaster = masterURL.pathExtension.lowercased() == "m3u8"
        guard defaultResolution != .auto else {
            return (masterURL, "Auto", nil)
        }
        let target = defaultResolution.rawValue
        let picked: ResolutionOption? = {
            if let exact = resolutions.first(where: { $0.resolutionId == target }) {
                return exact
            }
            return resolutions
                .filter { $0.resolutionId < target }
                .max(by: { $0.resolutionId < $1.resolutionId })
        }()
        guard let picked else { return (masterURL, "Auto", nil) }
        if isHLSMaster {
            return (masterURL, picked.label, picked.preferredMaximumResolution)
        }
        return (picked.url, picked.label, nil)
    }

    // MARK: - Player presentation

    private func presentPlayer(
        url: URL,
        autoURL: URL,
        initialLabel: String,
        preferredMaximumResolution: CGSize? = nil,
        resolutions: [ResolutionOption],
        accessToken: String?,
        videoId: String,
        numericVideoId: Int? = nil,
        title: String,
        apiClient: PeerTubeAPIClient,
        playlistQueue: PlaylistPlaybackQueue?,
        isLocalDownload: Bool,
        accountId: UUID?,
        prefetchedCaptions: [PeerTubeCaption]? = nil,
        durationSeconds: Int? = nil,
        nowPlaying: NowPlayingMetadata? = nil
    ) {
        guard let root = Self.keyWindow?.rootViewController else {
            PlaybackLog.log.error("presentPlayer: no root VC videoId=\(videoId, privacy: .public)")
            isPresenting = false
            return
        }

        let presenter = Self.topViewController(from: root)

        // Activated here rather than at launch, so opening the app doesn't stop other apps' audio.
        try? AVAudioSession.sharedInstance().setActive(true)

        let rawSaved: TimeInterval? = {
            guard let accountId else { return nil }
            return PlaybackPositionStore.position(for: videoId, accountId: accountId)
        }()
        let resumeSeconds = PlaybackPositionStore.effectiveResumePosition(
            stored: rawSaved,
            durationSeconds: durationSeconds
        )

        let asset = AVPlayerViewControllerRepresentable.makeAsset(
            url: url,
            accessToken: accessToken,
            instanceBaseURL: apiClient.baseURL
        )
        let item = AVPlayerItem(asset: asset)
        HLSPlaybackPreferences.applyPreferredMaximumResolution(preferredMaximumResolution, to: item)

        if let pos = resumeSeconds, pos > 0 {
            // Queue the seek before the item is attached to a player so HLS fetches segments at
            // the resume point instead of buffering from t=0 and throwing that data away.
            item.preferredForwardBufferDuration = 8
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            item.seek(
                to: CMTime(seconds: pos, preferredTimescale: 600),
                toleranceBefore: tolerance,
                toleranceAfter: tolerance,
                completionHandler: nil
            )
            PlaybackLog.log.notice("pre-seeking to \(pos, privacy: .public)s before attach videoId=\(videoId, privacy: .public)")
        } else {
            item.preferredForwardBufferDuration = PlayerSettings.bufferCap.preferredBufferSeconds(
                bytesPerSecond: resolutions.bufferBytesPerSecond(forQualityLabel: initialLabel)
            )
        }

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.modalPresentationStyle = .fullScreen
        playerVC.playbackControlsIncludeTransportBar = false
        // PiP runs from the container's own AVPlayerLayer; keep AVKit's built-in PiP from claiming the player.
        playerVC.allowsPictureInPicturePlayback = false
        if TransportBarConfiguration.requiresHidingAllSystemPlaybackControls {
            playerVC.showsPlaybackControls = false
        }

        let coordinator = PlayerCoordinator(
            resolutions: resolutions,
            autoURL: autoURL,
            initialLabel: initialLabel,
            accessToken: accessToken,
            player: player,
            controller: playerVC,
            videoId: videoId,
            numericVideoId: numericVideoId,
            title: title,
            apiClient: apiClient,
            playlistQueue: playlistQueue,
            isLocalDownload: isLocalDownload,
            instanceBaseURL: apiClient.baseURL,
            accountId: accountId,
            prefetchedCaptions: prefetchedCaptions,
            initialResumeAt: resumeSeconds
        ) { [weak self] in
            self?.isPresenting = false
        }
        coordinator.applyNowPlaying(nowPlaying)
        playerVC.delegate = coordinator

        // Wrap AVPlayerViewController in a container so focus routes to the overlay reliably.
        let container = PlayerContainerViewController(
            playerViewController: playerVC,
            overlayRoot: coordinator.transportBarRootView
        )
        coordinator.containerController = container
        coordinator.wireCaptionOverlay(using: container)
        coordinator.configurePictureInPicture(using: container)
        container.onDismissed = { [weak coordinator] in
            coordinator?.performDismissCleanup()
        }
        // Let the container consult the coordinator before dismissing on Menu/Back: a
        // pending visual-scrub commit is cancelled in place instead of closing the player.
        container.shouldConsumeMenuPress = { [weak coordinator] in
            coordinator?.handleMenuPressIfNeeded() ?? false
        }
        container.onPlayPausePress = { [weak coordinator] in
            coordinator?.handlePlayPausePress()
        }

        objc_setAssociatedObject(
            container, &AssociatedKeys.coordinator,
            coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        presenter.present(container, animated: true) {
            PlaybackLog.log.notice("AVPlayerViewController on-screen videoId=\(videoId, privacy: .public)")
        }
    }

    func beginPictureInPictureSession(coordinator: PlayerCoordinator, container: PlayerContainerViewController) {
        pictureInPictureSession = (coordinator, container)
        isPresenting = false
    }

    func releasePictureInPictureSession(matching coordinator: PlayerCoordinator) {
        guard pictureInPictureSession?.coordinator === coordinator else { return }
        pictureInPictureSession = nil
    }

    func notePictureInPictureRestoredToFullScreen() {
        isPresenting = true
    }

    func topViewControllerForPictureInPictureRestore() -> UIViewController? {
        guard let root = Self.keyWindow?.rootViewController else { return nil }
        return Self.topViewController(from: root)
    }

    // MARK: - Loading overlay

    private func showLoadingOverlay(on window: UIWindow) {
        removeLoadingOverlay()

        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.7)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        overlay.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])

        overlay.alpha = 0
        window.addSubview(overlay)
        UIView.animate(withDuration: 0.15) { overlay.alpha = 1 }

        loadingOverlay = overlay
    }

    private func removeLoadingOverlay() {
        guard let overlay = loadingOverlay else { return }
        loadingOverlay = nil
        UIView.animate(withDuration: 0.15, animations: {
            overlay.alpha = 0
        }, completion: { _ in
            overlay.removeFromSuperview()
        })
    }

    // MARK: - Helpers

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    static func topViewController(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return topViewController(from: presented)
        }
        if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
            return topViewController(from: visible)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(from: selected)
        }
        return vc
    }
}

private enum AssociatedKeys {
    static var coordinator: UInt8 = 0
}

// MARK: - Player Coordinator

/// Manages resolution/speed menus and dismissal for a UIKit-modally-presented
/// AVPlayerViewController. Single Menu press dismisses everything.
final class PlayerCoordinator: NSObject, AVPlayerViewControllerDelegate, AVPictureInPictureControllerDelegate {
    weak var player: AVPlayer?
    weak var controller: AVPlayerViewController?
    weak var containerController: UIViewController?
    private let onDismiss: () -> Void
    private var didCallDismiss = false

    private var resolutions: [ResolutionOption]
    private var autoURL: URL
    private let accessToken: String?
    private var videoId: String
    /// Numeric PeerTube video id for the currently playing item (needed to POST add-to-playlist).
    /// `nil` for local downloads or videos played without a decoded detail payload.
    private var numericVideoId: Int?
    /// Account name (username) resolved lazily from `usersMe` and cached for the playlist picker.
    private var cachedAccountName: String?
    private let apiClient: PeerTubeAPIClient?
    /// Snapshot from `apiClient.baseURL` at presentation time (avoids MainActor isolation in delegate methods).
    private let instanceBaseURL: URL?
    /// Account ID for storing playback positions per-account.
    private let accountId: UUID?
    private var playlistQueue: PlaylistPlaybackQueue?
    private var currentLabel: String
    /// Each video starts at the Default speed setting; the Speed menu and hold-for-2x change it for
    /// the current video only. Mirrored onto `AVPlayer.defaultRate` so any `play()` call resumes at
    /// this speed.
    private var currentSpeed: Float = PlayerSettings.defaultPlaybackSpeed
    private var nowPlaying: NowPlayingMetadata?
    /// Playback rate captured when the user's finger first latched the temporary touch-hold
    /// boost (non-nil => boost is active). Restored on finger-lift. We use `player.rate` at
    /// the moment of latching rather than `currentSpeed` so the restore matches what the user
    /// was actually hearing, even if the tracked speed had drifted (e.g. after a play-pause
    /// cycle resets rate to 1.0).
    private var rateBeforeTouchHoldBoost: Float?
    private var statusObservation: NSKeyValueObservation?
    private var initialLoadObservation: NSKeyValueObservation?
    private var loadingOverlay: UIView?
    private var isSwitching = false
    private var endObserver: Any?
    private var progressTimeObserver: Any?
    private let isLocalDownload: Bool
    private var transportBar: TransportBarController?
    private var pictureInPictureController: AVPictureInPictureController?
    private var isInPictureInPicture = false
    /// Set when a resolution or playlist swap replaces `AVPlayer` while PiP is up.
    /// The next PiP stop is that swap, not the user closing the window, so playback
    /// stays up and PiP is restarted if the system dropped it.
    private var resumePictureInPictureAfterPlayerSwap = false
    private var pictureInPicturePossibleObservation: NSKeyValueObservation?
    /// Pending start that waits for `isPictureInPicturePossible` after the source layer is handed the video.
    private var pendingPictureInPictureStart: DispatchWorkItem?
    private static let pictureInPictureStartTimeout: TimeInterval = 3
    private var title: String
    private weak var playlistPickerHost: UIViewController?
    private var captions: [PeerTubeCaption] = []
    /// Currently displayed caption track (`nil` = Off).
    private var selectedCaptionLanguage: String?
    /// Sorted by start time; empty when the video has none or the instance predates PeerTube 6.
    private var chapters: [VideoChapter] = []
    /// Next playlist item, prepared near the end of the current one so autoplay skips the
    /// detail/token/manifest round trips.
    private var nextItemPrefetch: PlaylistItemPrefetch?
    private var pendingResumeAt: TimeInterval?
    private var hasStartedInitialPlayback = false
    /// True while the initial seek to the saved resume point is in flight; `currentTime` can't be
    /// trusted until it lands.
    private var isSeekingToResumePoint = false
    private var resignActiveObserver: Any?
    private var lastPeriodicPositionSaveAt = Date.distantPast

    private static let watchReportInterval: Double = 30
    /// Prefetch the next playlist item once this little playback time remains. Kept short
    /// because the prefetched stream URL can carry a video file token that expires.
    private static let playlistPrefetchLeadTime: TimeInterval = 120
    /// Minimum gap between position saves from the progress observer, which also fires on every
    /// seek and play/pause. Each save rewrites the whole positions dictionary.
    private static let periodicPositionSaveMinInterval: TimeInterval = 5

    init(resolutions: [ResolutionOption], autoURL: URL, initialLabel: String, accessToken: String?,
         player: AVPlayer, controller: AVPlayerViewController,
         videoId: String, numericVideoId: Int?, title: String, apiClient: PeerTubeAPIClient?,
         playlistQueue: PlaylistPlaybackQueue?,
         isLocalDownload: Bool,
         instanceBaseURL: URL?,
         accountId: UUID?,
         prefetchedCaptions: [PeerTubeCaption]? = nil,
         initialResumeAt: TimeInterval? = nil,
         onDismiss: @escaping () -> Void) {
        self.resolutions = resolutions
        self.autoURL = autoURL
        self.currentLabel = initialLabel
        self.accessToken = accessToken
        self.player = player
        self.controller = controller
        self.videoId = videoId
        self.numericVideoId = numericVideoId
        self.title = title
        self.apiClient = apiClient
        self.instanceBaseURL = instanceBaseURL
        self.accountId = accountId
        self.playlistQueue = playlistQueue
        self.isLocalDownload = isLocalDownload
        self.pendingResumeAt = initialResumeAt.flatMap { $0 > 0 ? $0 : nil }
        self.onDismiss = onDismiss
        super.init()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }

        reportCurrentTime()
        startProgressReporting()
        observeInitialItemIfNeeded(player: player)
        // tvOS can end a suspended app without telling it, so don't wait for the player to close.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appWillResignActive()
        }

        transportBar = TransportBarController(
            showsQualityButton: !resolutions.isEmpty,
            showsSkipNextButton: Self.playlistHasNextItem(after: playlistQueue),
            showsAddToPlaylistButton: Self.canAddToPlaylist(accessToken: accessToken, numericVideoId: numericVideoId),
            title: title,
            onQualityTapped: { [weak self] in self?.presentQualityMenu() },
            onSpeedTapped: { [weak self] in self?.presentSpeedMenu() },
            onCaptionsTapped: { [weak self] in self?.presentCaptionsMenu() },
            onChaptersTapped: { [weak self] in self?.presentChaptersMenu() },
            onPictureInPictureTapped: { [weak self] in self?.startPictureInPicture() },
            onSkipNextTapped: { [weak self] in self?.userRequestedSkipToNextPlaylistItem() },
            onAddToPlaylistTapped: { [weak self] in self?.presentAddToPlaylistMenu() },
            onSpeedHold: { [weak self] in self?.toggleSpeedHold() },
            onTouchHoldBegan: { [weak self] in self?.startTouchHoldBoost() },
            onTouchHoldEnded: { [weak self] in self?.endTouchHoldBoost() }
        )
        transportBar?.attach(player: player)
        transportBar?.preferredPlaybackRate = currentSpeed
        player.defaultRate = currentSpeed
        fetchStoryboards(for: videoId)
        fetchChapters(for: videoId)
        if let pre = prefetchedCaptions, !pre.isEmpty {
            receivedCaptionsList(pre)
        } else if !isLocalDownload {
            fetchCaptions(for: videoId)
        }
    }

    /// Publishes title/channel immediately and adds artwork once it loads.
    func applyNowPlaying(_ metadata: NowPlayingMetadata?) {
        nowPlaying = metadata
        guard let metadata else {
            player?.currentItem?.externalMetadata = []
            return
        }
        player?.currentItem?.externalMetadata = metadata.metadataItems(artwork: nil)
        guard let artworkURL = metadata.artworkURL else { return }
        let requestedVideoId = videoId
        Task { @MainActor [weak self] in
            guard let artwork = await ImageCache.shared.load(artworkURL),
                  let self, self.videoId == requestedVideoId else { return }
            self.player?.currentItem?.externalMetadata = metadata.metadataItems(artwork: artwork)
        }
    }

    func wireCaptionOverlay(using container: PlayerContainerViewController) {
        transportBar?.onTimeUpdate = { [weak container] t in
            container?.captionOverlay.setCurrentTime(t)
        }
    }

    private func captionOverlayHost() -> CaptionOverlayView? {
        (containerController as? PlayerContainerViewController)?.captionOverlay
    }

    private func fetchCaptions(for id: String) {
        guard let apiClient else { return }
        Task { [weak self, vid = id] in
            await self?.loadCaptionsFromNetwork(id: vid, apiClient: apiClient)
        }
    }

    private func loadCaptionsFromNetwork(id: String, apiClient: PeerTubeAPIClient) async {
        do {
            let data = try await apiClient.rawRequest(.videoCaptions(id: id))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let resp = try decoder.decode(VideoCaptionsResponse.self, from: data)
            let list = (resp.data ?? []).peerTubeCaptions(instanceBase: self.instanceBaseURL)
            await MainActor.run { [weak self] in
                guard let self, self.videoId == id else { return }
                self.receivedCaptionsList(list)
            }
        } catch {
            PlaybackLog.log.notice("captions list unavailable videoId=\(id, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    private func receivedCaptionsList(_ list: [PeerTubeCaption]) {
        captions = list
        guard !list.isEmpty else {
            transportBar?.setShowsCaptionsButton(false)
            return
        }
        transportBar?.setShowsCaptionsButton(true)
        if let pref = PlayerSettings.preferredCaptionLanguage,
           list.contains(where: { $0.languageId == pref }) {
            Task { await applyCaption(languageId: pref) }
        }
    }

    private func presentCaptionsMenu() {
        guard let vc = containerController ?? controller else { return }
        let alert = UIAlertController(title: "Captions", message: nil, preferredStyle: .actionSheet)
        let offSelected = selectedCaptionLanguage == nil
        let offAction = UIAlertAction(title: Self.menuTitle("Off", selected: offSelected), style: .default) { [weak self] _ in
            Task { await self?.applyCaption(languageId: nil) }
        }
        alert.addAction(offAction)
        if offSelected { alert.preferredAction = offAction }
        for cap in captions {
            let isCurrent = cap.languageId == selectedCaptionLanguage
            let line = cap.displayLabel + (cap.automaticallyGenerated ? " (auto)" : "")
            let action = UIAlertAction(title: Self.menuTitle(line, selected: isCurrent), style: .default) { [weak self] _ in
                Task { await self?.applyCaption(languageId: cap.languageId) }
            }
            alert.addAction(action)
            if isCurrent { alert.preferredAction = action }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        vc.present(alert, animated: true)
    }

    private func captionURLRequest(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let token = accessToken, !token.isEmpty,
           let ih = instanceBaseURL?.host?.lowercased(),
           let ph = url.host?.lowercased(),
           ih == ph {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func applyCaption(languageId: String?) async {
        if languageId == nil {
            await MainActor.run {
                selectedCaptionLanguage = nil
                PlayerSettings.preferredCaptionLanguage = nil
                captionOverlayHost()?.clearCuesAndDisplay()
            }
            return
        }
        let cap = await MainActor.run { captions.first(where: { $0.languageId == languageId }) }
        guard let cap else { return }
        let sourceURL = cap.sourceURL
        let request = await MainActor.run { captionURLRequest(for: sourceURL) }
        do {
            let data: Data
            if sourceURL.isFileURL {
                // Offline sidecars: `URLSession` does not yield an HTTPURLResponse for `file://`,
                // so the status guard below would always fail and captions would never apply.
                data = try Data(contentsOf: sourceURL)
            } else {
                let (remoteData, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
                data = remoteData
            }
            guard let str = String(data: data, encoding: .utf8) else { return }
            let cues = WebVTTParser.parse(str)
            await MainActor.run {
                captionOverlayHost()?.setCues(cues)
                selectedCaptionLanguage = languageId
                PlayerSettings.preferredCaptionLanguage = languageId
            }
        } catch {
            PlaybackLog.log.notice("caption download failed videoId=\(self.videoId, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches the PeerTube per-video sprite-sheet storyboard and installs a provider on the
    /// transport bar so the skim / visual-scrub thumbnail popover can crop frames from it.
    /// Runs in the background; if the instance hasn't generated a storyboard (empty list / 404),
    /// the transport bar falls back to `AVAssetImageGenerator` (which effectively only works for
    /// local downloads).
    private func fetchStoryboards(for id: String) {
        guard !isLocalDownload, let apiClient else { return }
        Task { [weak self, videoId = id] in
            await self?.loadStoryboards(id: videoId, apiClient: apiClient)
        }
    }

    private func loadStoryboards(id: String, apiClient: PeerTubeAPIClient) async {
        do {
            let data = try await apiClient.rawRequest(.videoStoryboards(id: id))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let resp = try decoder.decode(VideoStoryboardsResponse.self, from: data)
            guard let storyboard = resp.storyboards.first,
                  let path = storyboard.sheetPath,
                  let sheetURL = await storyboardImageURL(path: path, apiClient: apiClient)
            else { return }

            let (imageData, _) = try await URLSession.shared.data(from: sheetURL)
            guard let rawSheet = UIImage(data: imageData) else { return }
            // Decode once up front; scrub thumbnails crop from this sheet on every skim tick.
            let sheet = await rawSheet.byPreparingForDisplay() ?? rawSheet

            let provider = StoryboardThumbnailProvider(sheet: sheet, storyboard: storyboard)
            await MainActor.run { [weak self] in
                // Guard against late arrivals after playlist transitions — only install if
                // `videoId` still matches.
                guard let self, self.videoId == id else { return }
                self.transportBar?.storyboardProvider = provider
            }
        } catch {
            PlaybackLog.log.notice("storyboards unavailable videoId=\(id, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches chapters for the scrubber markers and the Chapters menu. Instances older than
    /// PeerTube 6 return 404; any failure is treated as "no chapters". Local downloads try too,
    /// since chapters aren't stored with the file (offline, the request just fails).
    private func fetchChapters(for id: String) {
        guard let apiClient else { return }
        Task { [weak self, videoId = id] in
            await self?.loadChapters(id: videoId, apiClient: apiClient)
        }
    }

    private func loadChapters(id: String, apiClient: PeerTubeAPIClient) async {
        do {
            let resp: VideoChaptersResponse = try await apiClient.request(.videoChapters(id: id))
            let sorted = resp.chapters.sorted { $0.timecode < $1.timecode }
            await MainActor.run { [weak self] in
                // Same late-arrival guard as storyboards: a playlist transition may have moved on.
                guard let self, self.videoId == id else { return }
                self.chapters = sorted
                self.transportBar?.setChapters(sorted)
            }
        } catch {
            PlaybackLog.log.notice("chapters unavailable videoId=\(id, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func storyboardImageURL(path: String, apiClient: PeerTubeAPIClient) -> URL? {
        guard let base = apiClient.baseURL else { return nil }
        // Paths returned by the API are instance-rooted (e.g. `/lazy-static/storyboards/…`).
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    /// Expose the transport bar's root view so `PlayerContainerViewController` can install it
    /// as a sibling of the `AVPlayerViewController`'s view.
    var transportBarRootView: TransportBarRootView {
        guard let transportBar else {
            // `transportBar` is created unconditionally in `init`; this path should be impossible.
            fatalError("transportBar is nil — PlayerCoordinator.init did not create one")
        }
        return transportBar.rootView
    }

    /// Called by the container VC before dismissing on Menu/Back. Returns `true` if the transport
    /// bar consumed the press (e.g. cancelled a staged visual scrub), so dismissal is skipped.
    func handleMenuPressIfNeeded() -> Bool {
        transportBar?.handleMenuPressIfNeeded() ?? false
    }

    /// Called by the container VC when the Siri Remote Play/Pause button goes down.
    /// Fires once per press (no tap-vs-hold distinction) because the `.playPause` button has
    /// parallel AVKit / MPRemoteCommand paths we can't reliably suppress. Hold-for-speed
    /// lives on the touchpad click (`.select`) instead — see `toggleSpeedHold`.
    func handlePlayPausePress() {
        transportBar?.handlePlayPausePress()
    }

    /// Wired as `onSpeedHold` on the transport bar: toggles the playback rate between
    /// 2x and 1x when the user long-presses the touchpad click (`.select`). We deliberately
    /// bypass the "only if already playing" guard in `setSpeed` because the user held the
    /// button specifically to trigger this — they expect an immediate, observable change even
    /// if the video is paused. We also update `currentSpeed` so the new rate is reapplied
    /// after a resolution swap (which builds a fresh `AVPlayer`).
    ///
    /// The decision is based on `player.rate` rather than the stored `currentSpeed` because
    /// `AVPlayer.play()` always snaps rate back to 1.0, so `currentSpeed` can go stale after
    /// a tap-pause-then-tap-play cycle. Using the live rate ensures "hold" always gets to 2x
    /// first from any actual playback rate other than 2x (including paused → resume at 2x).
    private func toggleSpeedHold() {
        let fast: Float = 2.0
        let currentRate = player?.rate ?? 1.0
        let newSpeed: Float = abs(currentRate - fast) < 0.001 ? 1.0 : fast
        currentSpeed = newSpeed
        player?.defaultRate = newSpeed
        player?.rate = newSpeed
        transportBar?.preferredPlaybackRate = newSpeed
        transportBar?.showSpeedNotification("\(Int(newSpeed))x")
    }

    /// Fired when a finger rests on the Siri Remote touchpad past
    /// `TransportBarMetrics.touchHoldMinimumDuration`. Temporarily forces playback to 2x while
    /// recording the pre-boost rate. We deliberately skip the boost while paused so that the
    /// "hold finger, then swipe to scrub" flow still works (pan gesture takes over once the user
    /// starts moving). `currentSpeed` is *not* touched — this is a transient override and the
    /// user's chosen speed should persist across the boost.
    private func startTouchHoldBoost() {
        guard let player else { return }
        guard player.timeControlStatus != .paused else { return }
        guard rateBeforeTouchHoldBoost == nil else { return }

        rateBeforeTouchHoldBoost = player.rate
        player.rate = 2.0
    }

    /// Fired on finger-lift or gesture cancellation after `startTouchHoldBoost`. Restores the
    /// previously captured rate unless the player was paused while the boost was active (e.g.
    /// the user tapped Play/Pause during the hold), in which case we respect the pause and
    /// leave the rate at 0.
    private func endTouchHoldBoost() {
        guard let saved = rateBeforeTouchHoldBoost else { return }
        rateBeforeTouchHoldBoost = nil
        guard let player, player.rate > 0 else { return }
        player.rate = saved
    }

    deinit {
        initialLoadObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        if let progressTimeObserver, let player { player.removeTimeObserver(progressTimeObserver) }
    }

    /// First-load only: logs AVFoundation errors (often missing from API-layer logs).
    private func observeInitialItemIfNeeded(player: AVPlayer) {
        guard let item = player.currentItem else {
            PlaybackLog.log.error("AVPlayer has no currentItem videoId=\(self.videoId, privacy: .public)")
            return
        }
        initialLoadObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    PlaybackLog.log.notice("AVPlayerItem readyToPlay videoId=\(self.videoId, privacy: .public)")
                    self.initialLoadObservation?.invalidate()
                    self.initialLoadObservation = nil
                    self.beginInitialPlaybackIfNeeded()
                case .failed:
                    let err = item.error
                    PlaybackLog.log.error("AVPlayerItem failed videoId=\(self.videoId, privacy: .public) \(err?.localizedDescription ?? "nil", privacy: .public) underlying=\(String(describing: err), privacy: .public)")
                    if let ne = err as NSError? {
                        PlaybackLog.log.error("NSError domain=\(ne.domain, privacy: .public) code=\(ne.code)")
                    }
                    self.initialLoadObservation?.invalidate()
                    self.initialLoadObservation = nil
                    let message = err?.localizedDescription ?? "The stream could not be opened."
                    if let vc = self.containerController ?? self.controller {
                        let alert = UIAlertController(title: "Playback failed", message: message, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                            self?.dismissPlayer()
                        })
                        vc.present(alert, animated: true)
                    } else {
                        self.dismissPlayer()
                    }
                default:
                    break
                }
            }
        }
    }

    /// Forward-buffer hint for the quality now selected: the Buffer cap setting converted from
    /// megabytes to seconds at that rendition's data rate.
    private var preferredBufferSeconds: Double {
        PlayerSettings.bufferCap.preferredBufferSeconds(
            bytesPerSecond: resolutions.bufferBytesPerSecond(forQualityLabel: currentLabel)
        )
    }

    /// Resumes playback at the given rate, using `playImmediately` when buffer is already ready.
    private func resumePlayer(_ player: AVPlayer, at rate: Float) {
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
           player.currentItem?.isPlaybackLikelyToKeepUp == true {
            player.playImmediately(atRate: rate)
        } else {
            player.play()
            if abs(player.rate - rate) > 0.001 {
                player.rate = rate
            }
        }
    }

    /// Called once a swapped `AVPlayerItem` reaches `.readyToPlay`. Seeks on the live player,
    /// then resumes — never relies on a pre-seek queued before the item was attached.
    private func handleQualitySwapReady(
        player: AVPlayer,
        item: AVPlayerItem,
        seekSeconds: TimeInterval,
        targetSpeed: Float
    ) {
        statusObservation?.invalidate()
        statusObservation = nil

        let time = CMTime(seconds: max(0, seekSeconds), preferredTimescale: 600)
        let tolerance = CMTime(seconds: 2, preferredTimescale: 600)

        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                if !finished {
                    PlaybackLog.log.error(
                        "resolution switch seek incomplete videoId=\(self.videoId, privacy: .public) target=\(seekSeconds, privacy: .public)s"
                    )
                }
                player.play()
                if abs(player.rate - targetSpeed) > 0.001 {
                    player.rate = targetSpeed
                }
                self.transportBar?.clearHeldPlayhead()
                self.transportBar?.preferredPlaybackRate = targetSpeed
                self.isSwitching = false
                self.removeLoadingOverlay()
                if let lang = self.selectedCaptionLanguage,
                   self.captions.contains(where: { $0.languageId == lang }) {
                    Task { await self.applyCaption(languageId: lang) }
                }
            }
        }
    }

    /// Starts playback once the item is ready. When resuming from a saved timestamp the item
    /// was already pre-seeked in `presentPlayer`; restore the full buffer cap and start playback.
    private func beginInitialPlaybackIfNeeded() {
        guard !hasStartedInitialPlayback else { return }
        hasStartedInitialPlayback = true
        guard let player else { return }
        announceStartingSpeedIfNeeded()

        if let resumeAt = pendingResumeAt {
            pendingResumeAt = nil
            player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds

            let current = CMTimeGetSeconds(player.currentTime())
            let alreadyAtTarget = current.isFinite && abs(current - resumeAt) <= 2.0

            if alreadyAtTarget {
                PlaybackLog.log.notice("resuming playback at \(resumeAt, privacy: .public)s videoId=\(self.videoId, privacy: .public)")
                resumePlayer(player, at: currentSpeed)
            } else {
                let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
                isSeekingToResumePoint = true
                player.seek(
                    to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                    toleranceBefore: tolerance,
                    toleranceAfter: tolerance
                ) { [weak self] _ in
                    guard let self, let player = self.player else { return }
                    DispatchQueue.main.async {
                        self.isSeekingToResumePoint = false
                        self.resumePlayer(player, at: self.currentSpeed)
                    }
                }
                PlaybackLog.log.notice("confirming resume seek to \(resumeAt, privacy: .public)s videoId=\(self.videoId, privacy: .public)")
            }
        } else {
            resumePlayer(player, at: currentSpeed)
        }
    }

    // MARK: - End of item / playlist autoplay

    private static func playlistHasNextItem(after queue: PlaylistPlaybackQueue?) -> Bool {
        guard let queue else { return false }
        return queue.currentIndex + 1 < queue.videoIds.count
    }

    private func refreshSkipNextButtonVisibility() {
        transportBar?.setShowsSkipNext(Self.playlistHasNextItem(after: playlistQueue))
    }

    // MARK: - Add to playlist

    /// The add-to-playlist control only makes sense for signed-in playback of a video with a
    /// numeric id we can POST (so federated/anonymous playback and local downloads hide it).
    private static func canAddToPlaylist(accessToken: String?, numericVideoId: Int?) -> Bool {
        guard let accessToken, !accessToken.isEmpty else { return false }
        return numericVideoId != nil
    }

    private func refreshAddToPlaylistButtonVisibility() {
        transportBar?.setShowsAddToPlaylistButton(
            Self.canAddToPlaylist(accessToken: accessToken, numericVideoId: numericVideoId)
        )
    }

    /// Presents the same SwiftUI playlist picker used on the video detail screen.
    private func presentAddToPlaylistMenu() {
        guard let apiClient, let numericVideoId,
              let presenter = containerController ?? controller else { return }
        transportBar?.pauseIfPlaying()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let name = await self.resolveAccountName(apiClient: apiClient), !name.isEmpty else {
                self.transportBar?.showSpeedNotification("Couldn’t load playlists")
                return
            }
            let pickerVM = PlaylistPickerViewModel()
            pickerVM.configure(apiClient: apiClient, accountName: name, numericVideoId: numericVideoId)
            let host = UIHostingController(rootView: PlaylistPickerView(vm: pickerVM))
            host.modalPresentationStyle = .overFullScreen
            // Let the SwiftUI picker's own background fill the screen (it draws a dark backdrop);
            // otherwise the player video shows through this over-full-screen presentation.
            host.view.backgroundColor = .clear
            self.playlistPickerHost = host
            presenter.present(host, animated: true)
        }
    }

    private func resolveAccountName(apiClient: PeerTubeAPIClient) async -> String? {
        if let cachedAccountName, !cachedAccountName.isEmpty { return cachedAccountName }
        do {
            let me: UserMe = try await apiClient.request(.usersMe)
            cachedAccountName = me.username
            return me.username
        } catch {
            return nil
        }
    }

    /// Advances to the next playlist item when one exists. Used by end-of-playback autoplay and
    /// the transport-bar "skip next" control.
    private func advanceToNextPlaylistItemIfPossible() {
        guard let queue = playlistQueue,
              queue.currentIndex + 1 < queue.videoIds.count else { return }
        let nextId = queue.videoIds[queue.currentIndex + 1]
        let nextQueue = PlaylistPlaybackQueue(
            videoIds: queue.videoIds,
            currentIndex: queue.currentIndex + 1,
            autoplayEnabled: queue.autoplayEnabled,
            apiClient: queue.apiClient,
            accessToken: queue.accessToken
        )
        NotificationCenter.default.post(
            name: .peerTVPlaylistNowPlayingVideoId,
            object: nil,
            userInfo: ["videoId": nextId]
        )
        Task { @MainActor [weak self] in
            await self?.transitionToNextPlaylistItem(nextQueue: nextQueue, nextVideoId: nextId)
        }
    }

    private func userRequestedSkipToNextPlaylistItem() {
        guard !isSwitching, Self.playlistHasNextItem(after: playlistQueue) else { return }
        reportCurrentTime()
        savePlaybackPosition()
        advanceToNextPlaylistItemIfPossible()
    }

    private func handlePlaybackEnded() {
        reportCurrentTime()
        clearPlaybackPosition()
        if let queue = playlistQueue,
           queue.autoplayEnabled,
           queue.currentIndex + 1 < queue.videoIds.count {
            advanceToNextPlaylistItemIfPossible()
            return
        }
        dismissPlayer()
    }

    /// Dismisses the container (and thus the embedded `AVPlayerViewController`). `performDismissCleanup`
    /// is invoked by the container's `onDismissed` callback, so we don't need to call it again here.
    private func dismissPlayer() {
        let vc = containerController ?? controller
        vc?.dismiss(animated: true)
    }

    /// Keeps the same `AVPlayerViewController` open and swaps the item (no flash back to the playlist).
    @MainActor
    private func transitionToNextPlaylistItem(nextQueue: PlaylistPlaybackQueue, nextVideoId: String) async {
        guard let player, let controller, !didCallDismiss else { return }

        isSwitching = true
        player.pause()
        initialLoadObservation?.invalidate()
        initialLoadObservation = nil
        showLoadingOverlay(in: controller)

        do {
            let prepared = try await takePreparedPlaylistItem(videoId: nextVideoId, queue: nextQueue)
            let video = prepared.video
            let url = prepared.url

            if let oldObs = endObserver {
                NotificationCenter.default.removeObserver(oldObs)
            }
            endObserver = nil
            statusObservation?.invalidate()
            statusObservation = nil

            videoId = nextVideoId
            numericVideoId = video.id
            playlistQueue = nextQueue
            refreshSkipNextButtonVisibility()
            refreshAddToPlaylistButtonVisibility()
            captions = []
            selectedCaptionLanguage = nil
            transportBar?.setShowsCaptionsButton(false)
            captionOverlayHost()?.clearCuesAndDisplay()
            resolutions = video.resolutionOptions
            autoURL = url
            // Apply the default-resolution setting to the next item too.
            let pick = PlayerPresenter.chooseInitialPlayback(
                resolutions: resolutions,
                masterURL: url,
                defaultResolution: PlayerSettings.defaultResolution
            )
            currentLabel = pick.label
            title = video.name ?? ""
            transportBar?.setTitle(title)
            // Drop stale storyboard and chapters; the fetches below re-install them for the new item.
            transportBar?.storyboardProvider = nil
            chapters = []
            transportBar?.setChapters([])
            fetchStoryboards(for: nextVideoId)
            fetchChapters(for: nextVideoId)
            fetchCaptions(for: nextVideoId)
            // Like a freshly opened video, start at the default speed; a speed picked for the
            // previous item doesn't carry over. `adoptPlayer` copies it onto the new player.
            currentSpeed = PlayerSettings.defaultPlaybackSpeed
            transportBar?.preferredPlaybackRate = currentSpeed

            let newItem = AVPlayerItem(asset: prepared.asset)
            newItem.preferredForwardBufferDuration = preferredBufferSeconds
            HLSPlaybackPreferences.applyPreferredMaximumResolution(pick.preferredMaximumResolution, to: newItem)

            if let obs = progressTimeObserver, let p = self.player {
                p.removeTimeObserver(obs)
                progressTimeObserver = nil
            }

            transportBar?.detach()

            let newPlayer = AVPlayer(playerItem: newItem)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            adoptPlayer(newPlayer, controller: controller)
            applyNowPlaying(NowPlayingMetadata(video: video, apiBaseURL: nextQueue.apiClient.baseURL))
            transportBar?.attach(player: newPlayer)

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: newItem,
                queue: .main
            ) { [weak self] _ in
                self?.handlePlaybackEnded()
            }
            startProgressReporting()

            let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
            statusObservation = newItem.observe(\.status, options: [.new]) { [weak self, weak newPlayer] item, _ in
                DispatchQueue.main.async {
                    guard let self, let newPlayer else { return }
                    if item.status == .readyToPlay {
                        self.statusObservation?.invalidate()
                        self.statusObservation = nil
                        newPlayer.seek(to: .zero, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                            guard finished else { return }
                            DispatchQueue.main.async {
                                newPlayer.rate = self.currentSpeed
                                self.isSwitching = false
                                self.removeLoadingOverlay()
                                newPlayer.play()
                                self.announceStartingSpeedIfNeeded()
                            }
                        }
                    } else if item.status == .failed {
                        let err = item.error
                        PlaybackLog.log.error("playlist item failed videoId=\(self.videoId, privacy: .public) \(err?.localizedDescription ?? "nil", privacy: .public)")
                        self.statusObservation?.invalidate()
                        self.statusObservation = nil
                        self.isSwitching = false
                        self.removeLoadingOverlay()
                        self.dismissPlayer()
                    }
                }
            }
        } catch {
            PlaybackLog.log.error("playlist transition videoDetail failed videoId=\(nextVideoId, privacy: .public) \(error.localizedDescription, privacy: .public)")
            isSwitching = false
            removeLoadingOverlay()
            dismissPlayer()
        }
    }

    // MARK: Playlist prefetch

    /// Fetches the item's detail, applies any video file token, and builds its asset.
    @MainActor
    private static func preparePlaylistItem(videoId: String, queue: PlaylistPlaybackQueue) async throws -> PreparedPlaylistItem {
        let data = try await queue.apiClient.rawRequest(.videoDetail(id: videoId))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let video = try decoder.decode(Video.self, from: data)

        guard let rawURL = video.hlsPlaylistURL ?? video.playbackURL else {
            throw URLError(.badURL)
        }
        let url = await PlayerPresenter.urlWithHLSTokenIfNeeded(
            url: rawURL,
            videoId: videoId,
            apiClient: queue.apiClient,
            accessToken: queue.accessToken
        )
        let asset = AVPlayerViewControllerRepresentable.makeAsset(
            url: url,
            accessToken: queue.accessToken,
            instanceBaseURL: queue.apiClient.baseURL
        )
        return PreparedPlaylistItem(video: video, url: url, asset: asset)
    }

    /// Starts preparing the next playlist item once `playlistPrefetchLeadTime` remains. Called
    /// from the progress observer, which also fires when playback starts (covers short videos).
    private func prefetchNextPlaylistItemIfNeeded() {
        guard let queue = playlistQueue,
              queue.currentIndex + 1 < queue.videoIds.count,
              let player, let item = player.currentItem else { return }
        let nextId = queue.videoIds[queue.currentIndex + 1]
        if let existing = nextItemPrefetch, existing.videoId == nextId, !existing.isStale { return }
        let duration = CMTimeGetSeconds(item.duration)
        let current = CMTimeGetSeconds(player.currentTime())
        guard duration.isFinite, current.isFinite,
              duration - current <= Self.playlistPrefetchLeadTime else { return }

        nextItemPrefetch?.task.cancel()
        let task = Task { @MainActor () -> PreparedPlaylistItem? in
            guard let prepared = try? await Self.preparePlaylistItem(videoId: nextId, queue: queue) else {
                return nil
            }
            // Load the HLS master playlist now so the new item skips that round trip too.
            _ = try? await prepared.asset.load(.isPlayable)
            return prepared
        }
        nextItemPrefetch = PlaylistItemPrefetch(videoId: nextId, startedAt: Date(), task: task)
        PlaybackLog.log.notice("prefetching next playlist item videoId=\(nextId, privacy: .public)")
    }

    /// Uses the prefetch when it's for this item and still fresh; otherwise prepares it now.
    @MainActor
    private func takePreparedPlaylistItem(videoId: String, queue: PlaylistPlaybackQueue) async throws -> PreparedPlaylistItem {
        let prefetch = nextItemPrefetch
        nextItemPrefetch = nil
        if let prefetch, prefetch.videoId == videoId, !prefetch.isStale,
           let prepared = await prefetch.task.value {
            PlaybackLog.log.notice("using prefetched playlist item videoId=\(videoId, privacy: .public)")
            return prepared
        }
        prefetch?.task.cancel()
        return try await Self.preparePlaylistItem(videoId: videoId, queue: queue)
    }

    // MARK: Watch history reporting

    private func startProgressReporting() {
        let interval = CMTime(seconds: Self.watchReportInterval, preferredTimescale: 600)
        progressTimeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] _ in
            self?.reportCurrentTime()
            self?.savePlaybackPositionMidPlayback(throttled: true)
            self?.prefetchNextPlaylistItemIfNeeded()
        }
    }

    private func appWillResignActive() {
        guard !didCallDismiss else { return }
        reportCurrentTime()
        savePlaybackPositionMidPlayback(throttled: false)
    }

    private func reportCurrentTime() {
        guard accountId != nil else { return }
        guard let player, let apiClient else { return }
        let raw = CMTimeGetSeconds(player.currentTime())
        guard raw.isFinite else { return }
        let seconds = Int(raw)
        Task { [videoId] in
            _ = try? await apiClient.rawRequest(.watchVideo(id: videoId, currentTime: max(0, seconds)))
        }
    }

    private func savePlaybackPosition() {
        guard let accountId, let player else { return }
        let currentTime = CMTimeGetSeconds(player.currentTime())
        guard currentTime.isFinite else { return }
        let duration: TimeInterval = {
            guard let item = player.currentItem else { return 0 }
            let d = CMTimeGetSeconds(item.duration)
            return d.isFinite ? d : 0
        }()
        PlaybackPositionStore.save(
            position: currentTime,
            duration: duration,
            videoId: videoId,
            accountId: accountId
        )
    }

    /// Saves the resume point while the video is still open, so a crash or tvOS ending the
    /// suspended app doesn't lose it. Skipped until the player has settled on its real position:
    /// during the initial resume seek or a quality/playlist swap `currentTime` reads near zero,
    /// and saving that would erase the stored point.
    private func savePlaybackPositionMidPlayback(throttled: Bool) {
        guard hasStartedInitialPlayback, !isSeekingToResumePoint, !isSwitching, !didCallDismiss else { return }
        if throttled {
            let now = Date()
            guard now.timeIntervalSince(lastPeriodicPositionSaveAt) >= Self.periodicPositionSaveMinInterval else {
                return
            }
            lastPeriodicPositionSaveAt = now
        }
        savePlaybackPosition()
    }

    private func clearPlaybackPosition() {
        guard let accountId else { return }
        PlaybackPositionStore.remove(videoId: videoId, accountId: accountId)
    }

    // MARK: Picture in Picture

    func configurePictureInPicture(using container: PlayerContainerViewController) {
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        guard supported, let player else {
            transportBar?.setShowsPictureInPictureButton(false)
            logPictureInPicture("configure skipped supported=\(supported) player=\(self.player != nil)")
            return
        }
        container.setPictureInPicturePlayer(player)
        guard pictureInPictureController == nil else {
            transportBar?.setShowsPictureInPictureButton(true)
            logPictureInPicture("configure reused controller \(pictureInPictureStateSummary())")
            return
        }
        let pip = AVPictureInPictureController(contentSource: .init(playerLayer: container.pipSourceLayer))
        pip.delegate = self
        pictureInPictureController = pip
        pictureInPicturePossibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, change in
            DispatchQueue.main.async {
                self?.pictureInPicturePossibleChanged(change.newValue ?? false)
            }
        }
        transportBar?.setShowsPictureInPictureButton(true)
        logPictureInPicture("configure created controller \(pictureInPictureStateSummary())")
    }

    private func startPictureInPicture() {
        logPictureInPicture("start requested \(pictureInPictureStateSummary())")
        guard let pictureInPictureController else {
            logPictureInPicture("start aborted: no controller")
            return
        }
        guard !pictureInPictureController.isPictureInPictureActive, pendingPictureInPictureStart == nil else {
            logPictureInPicture("start aborted: already active or starting")
            return
        }
        handVideoToPictureInPictureSource()
        if pictureInPictureController.isPictureInPicturePossible {
            beginPictureInPicture()
            return
        }
        logPictureInPicture("waiting for isPictureInPicturePossible after handing video to source layer")
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPictureInPictureStart = nil
            self.logPictureInPicture("start timed out; restoring full-screen player \(self.pictureInPictureStateSummary())")
            self.returnVideoToFullScreenPlayer()
        }
        pendingPictureInPictureStart = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pictureInPictureStartTimeout, execute: timeout)
    }

    private func pictureInPicturePossibleChanged(_ possible: Bool) {
        logPictureInPicture("isPictureInPicturePossible changed to \(possible)")
        guard possible, pendingPictureInPictureStart != nil else { return }
        beginPictureInPicture()
    }

    private func beginPictureInPicture() {
        pendingPictureInPictureStart?.cancel()
        pendingPictureInPictureStart = nil
        pictureInPictureController?.startPictureInPicture()
        logPictureInPicture("startPictureInPicture() called \(pictureInPictureStateSummary())")
    }

    /// Detaches the player from `AVPlayerViewController` so the PiP source layer owns the video
    /// and is visible. AVKit keeps `isPictureInPicturePossible` false while the video is
    /// rendered by another view on top of the source layer.
    private func handVideoToPictureInPictureSource() {
        let container = containerController as? PlayerContainerViewController
        container?.setPictureInPictureSourceInFront(true)
        let playbackRate = player?.rate ?? 0
        controller?.player = nil
        if playbackRate > 0 {
            player?.rate = playbackRate
        }
    }

    private func returnVideoToFullScreenPlayer() {
        (containerController as? PlayerContainerViewController)?.setPictureInPictureSourceInFront(false)
        let playbackRate = player?.rate ?? 0
        reattachFullScreenPlayerIfNeeded()
        if playbackRate > 0 {
            player?.rate = playbackRate
        }
    }

    private func logPictureInPicture(_ message: String) {
        PlaybackLog.log.notice("[PiP] \(message, privacy: .public)")
    }

    private func pictureInPictureStateSummary() -> String {
        let pip = pictureInPictureController
        let layer = (containerController as? PlayerContainerViewController)?.pipSourceLayer
        let itemStatus: String = {
            switch player?.currentItem?.status {
            case .readyToPlay: return "ready"
            case .failed: return "failed \(player?.currentItem?.error?.localizedDescription ?? "")"
            case .unknown: return "unknown"
            default: return "nil"
            }
        }()
        let bounds = layer?.bounds ?? .zero
        return "supported=\(AVPictureInPictureController.isPictureInPictureSupported()) possible=\(pip?.isPictureInPicturePossible ?? false) active=\(pip?.isPictureInPictureActive ?? false) controller=\(pip != nil) rate=\(player?.rate ?? -1) item=\(itemStatus) layerInHierarchy=\(layer?.superlayer != nil) layerBounds=\(Int(bounds.width))x\(Int(bounds.height)) layerReady=\(layer?.isReadyForDisplay ?? false) samePlayer=\(layer?.player === player) vcPlayer=\(controller?.player != nil)"
    }

    /// Stops the corner window and runs the normal end-of-playback cleanup.
    /// Used when the user starts a different video while one is still in Picture in Picture.
    func stopPictureInPictureAndCleanup() {
        isInPictureInPicture = false
        resumePictureInPictureAfterPlayerSwap = false
        pendingPictureInPictureStart?.cancel()
        pendingPictureInPictureStart = nil
        pictureInPicturePossibleObservation = nil
        let pip = pictureInPictureController
        pictureInPictureController = nil
        pip?.delegate = nil
        pip?.stopPictureInPicture()
        let container = containerController
        performDismissCleanup()
        if container?.presentingViewController != nil {
            (container as? PlayerContainerViewController)?.dismissForPictureInPicture(animated: false)
        }
    }

    /// Installs `newPlayer` on the full-screen controller and the PiP source layer.
    /// While Picture in Picture is active the full-screen controller is off-screen and
    /// must not take the player — assigning it there pauses playback.
    private func adoptPlayer(_ newPlayer: AVPlayer, controller: AVPlayerViewController) {
        newPlayer.defaultRate = currentSpeed
        player = newPlayer
        if isInPictureInPicture {
            notePictureInPicturePlayerReplaced()
        } else {
            controller.player = newPlayer
        }
        (containerController as? PlayerContainerViewController)?.setPictureInPicturePlayer(newPlayer)
    }

    private func notePictureInPicturePlayerReplaced() {
        resumePictureInPictureAfterPlayerSwap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.resumePictureInPictureAfterPlayerSwap else { return }
            if self.pictureInPictureController?.isPictureInPictureActive == true {
                self.resumePictureInPictureAfterPlayerSwap = false
            }
        }
    }

    private func reattachFullScreenPlayerIfNeeded() {
        guard let player, controller?.player !== player else { return }
        controller?.player = player
    }

    // MARK: Delegate

    func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        // AVPlayerViewController runs its own internal Menu-press gesture recognizer on tvOS
        // that asks this delegate (outside the regular `pressesBegan` chain). Returning `false`
        // here when a visual-scrub is staged stops AVKit from tearing down the container, and
        // `handleMenuPressIfNeeded()` cancels the scrub in the same call.
        let consumed = transportBar?.handleMenuPressIfNeeded() == true
        return !consumed
    }

    func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        performDismissCleanup()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        logPictureInPicture("willStart \(pictureInPictureStateSummary())")
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        logPictureInPicture("didStart \(pictureInPictureStateSummary())")
        isInPictureInPicture = true
        resumePictureInPictureAfterPlayerSwap = false
        // AVPlayerViewController pauses its player when its view leaves the window.
        // Detach first so the shared player keeps running in the corner window.
        let playbackRate = player?.rate ?? 0
        controller?.player = nil
        if playbackRate > 0 {
            player?.rate = playbackRate
        }
        guard let container = containerController as? PlayerContainerViewController else { return }
        MainActor.assumeIsolated {
            PlayerPresenter.shared.beginPictureInPictureSession(coordinator: self, container: container)
        }
        if container.viewIfLoaded?.window != nil || container.presentingViewController != nil {
            container.dismissForPictureInPicture()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        logPictureInPicture("restore requested \(pictureInPictureStateSummary())")
        guard let container = containerController else {
            logPictureInPicture("restore failed: no container")
            completionHandler(false)
            return
        }
        returnVideoToFullScreenPlayer()
        if container.viewIfLoaded?.window != nil || container.presentingViewController != nil {
            MainActor.assumeIsolated {
                PlayerPresenter.shared.notePictureInPictureRestoredToFullScreen()
            }
            completionHandler(true)
            return
        }
        let presenter: UIViewController? = MainActor.assumeIsolated {
            PlayerPresenter.shared.topViewControllerForPictureInPictureRestore()
        }
        guard let presenter, presenter !== container else {
            logPictureInPicture("restore failed: no presenter")
            completionHandler(false)
            return
        }
        MainActor.assumeIsolated {
            PlayerPresenter.shared.notePictureInPictureRestoredToFullScreen()
        }
        presenter.present(container, animated: true) {
            completionHandler(true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        logPictureInPicture("didStop swapResume=\(resumePictureInPictureAfterPlayerSwap) \(pictureInPictureStateSummary())")
        if resumePictureInPictureAfterPlayerSwap {
            resumePictureInPictureAfterPlayerSwap = false
            isInPictureInPicture = false
            // Don't call start from inside the stop callback; AVKit ignores it.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didCallDismiss else { return }
                self.pictureInPictureController?.startPictureInPicture()
            }
            return
        }
        let onScreen = containerController?.viewIfLoaded?.window != nil
            || containerController?.presentingViewController != nil
        isInPictureInPicture = false
        if onScreen {
            returnVideoToFullScreenPlayer()
        } else {
            pictureInPicturePossibleObservation = nil
            self.pictureInPictureController?.delegate = nil
            self.pictureInPictureController = nil
            performDismissCleanup()
        }
        MainActor.assumeIsolated {
            PlayerPresenter.shared.releasePictureInPictureSession(matching: self)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let ns = error as NSError
        logPictureInPicture("failedToStart domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription) \(pictureInPictureStateSummary())")
        returnVideoToFullScreenPlayer()
    }

    func performDismissCleanup() {
        guard !isInPictureInPicture else { return }
        guard !didCallDismiss else { return }
        didCallDismiss = true
        let dismissedVideoId = videoId
        Task { @MainActor in
            if AnonymousHistoryStore.shared.isActive {
                AnonymousHistoryStore.shared.finalizeTileSnapshot(for: dismissedVideoId)
            }
        }
        reportCurrentTime()
        savePlaybackPosition()
        player?.pause()
        statusObservation = nil
        nextItemPrefetch?.task.cancel()
        nextItemPrefetch = nil
        captions = []
        selectedCaptionLanguage = nil
        captionOverlayHost()?.clearCuesAndDisplay()
        transportBar?.setShowsCaptionsButton(false)
        transportBar?.tearDown()
        transportBar = nil
        removeLoadingOverlay()
        NotificationCenter.default.post(
            name: .peerTVPlayerDismissed,
            object: nil,
            userInfo: ["videoId": videoId]
        )
        onDismiss()
    }

    // MARK: Menus (action sheets; native transport bar is hidden)

    private func presentQualityMenu() {
        guard let vc = containerController ?? controller, !resolutions.isEmpty else { return }
        let alert = UIAlertController(title: "Quality", message: nil, preferredStyle: .actionSheet)
        let selected = currentLabel
        let autoAction = UIAlertAction(title: Self.menuTitle("Auto", selected: selected == "Auto"), style: .default) { [weak self] _ in
            self?.switchItem(to: nil)
        }
        alert.addAction(autoAction)
        if selected == "Auto" { alert.preferredAction = autoAction }
        for option in resolutions {
            let isCurrent = option.label == selected
            let action = UIAlertAction(title: Self.menuTitle(option.label, selected: isCurrent), style: .default) { [weak self] _ in
                self?.switchItem(to: option)
            }
            alert.addAction(action)
            if isCurrent { alert.preferredAction = action }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        vc.present(alert, animated: true)
    }

    private func presentSpeedMenu() {
        guard let vc = containerController ?? controller else { return }
        let alert = UIAlertController(title: "Speed", message: nil, preferredStyle: .actionSheet)
        for speed in PlayerSettings.playbackSpeeds {
            let isCurrent = abs(speed - currentSpeed) < 0.001
            let action = UIAlertAction(title: Self.menuTitle(PlayerSettings.speedLabel(speed), selected: isCurrent), style: .default) { [weak self] _ in
                self?.setSpeed(speed)
            }
            alert.addAction(action)
            if isCurrent { alert.preferredAction = action }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        vc.present(alert, animated: true)
    }

    private func presentChaptersMenu() {
        guard let vc = containerController ?? controller, !chapters.isEmpty else { return }
        let alert = UIAlertController(title: "Chapters", message: nil, preferredStyle: .actionSheet)
        let now = player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        let currentIndex = chapters.chapterIndex(at: now.isFinite ? now : 0)
        for (index, chapter) in chapters.enumerated() {
            let isCurrent = index == currentIndex
            let line = "\(TransportBarOverlayView.fmt(chapter.timecode))  \(chapter.title)"
            let action = UIAlertAction(title: Self.menuTitle(line, selected: isCurrent), style: .default) { [weak self] _ in
                self?.transportBar?.seek(to: chapter.timecode)
            }
            alert.addAction(action)
            if isCurrent { alert.preferredAction = action }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        vc.present(alert, animated: true)
    }

    /// Prefixes a checkmark to the title of the currently selected option so users can scan the
    /// list and see which one is active. Pairs with `UIAlertController.preferredAction` which
    /// also bolds / pre-focuses that same entry.
    private static func menuTitle(_ label: String, selected: Bool) -> String {
        selected ? "✓  \(label)" : label
    }

    // MARK: Actions

    private func switchItem(to option: ResolutionOption?) {
        guard let player, let controller, !isSwitching else { return }

        let seekSeconds = CMTimeGetSeconds(player.currentTime())
        guard seekSeconds.isFinite else { return }
        let targetSpeed = currentSpeed
        let isHLSMaster = autoURL.pathExtension.lowercased() == "m3u8"
        let label = option?.label ?? "Auto"
        guard label != currentLabel else { return }

        // HLS: load the resolution-specific variant playlist when picking a fixed quality
        // (a real URL change AVFoundation can switch on). Auto keeps the master playlist.
        // Initial playback still uses the master + `preferredMaximumResolution` for audio.
        let targetURL: URL
        let isHLSToMasterAuto: Bool
        if isHLSMaster {
            if let option {
                targetURL = option.url
                isHLSToMasterAuto = false
            } else {
                targetURL = autoURL
                isHLSToMasterAuto = true
            }
        } else {
            targetURL = option?.url ?? autoURL
            isHLSToMasterAuto = false
        }

        currentLabel = label
        isSwitching = true
        statusObservation?.invalidate()
        statusObservation = nil

        player.pause()
        showLoadingOverlay(in: controller)

        let ext = targetURL.pathExtension.lowercased()
        if ext == "m3u8", let apiClient {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let withToken = await PlayerPresenter.urlWithHLSTokenIfNeeded(
                    url: targetURL,
                    videoId: self.videoId,
                    apiClient: apiClient,
                    accessToken: self.accessToken
                )
                let asset = AVPlayerViewControllerRepresentable.makeAsset(
                    url: withToken,
                    accessToken: self.accessToken,
                    instanceBaseURL: self.instanceBaseURL
                )
                self.performAssetSwap(
                    asset: asset,
                    seekSeconds: seekSeconds,
                    targetSpeed: targetSpeed,
                    isHLSToMasterAuto: isHLSToMasterAuto,
                    controller: controller
                )
            }
        } else {
            let asset = AVPlayerViewControllerRepresentable.makeAsset(
                url: targetURL,
                accessToken: accessToken,
                instanceBaseURL: instanceBaseURL
            )
            performAssetSwap(
                asset: asset,
                seekSeconds: seekSeconds,
                targetSpeed: targetSpeed,
                isHLSToMasterAuto: isHLSToMasterAuto,
                controller: controller
            )
        }
    }

    private func performAssetSwap(
        asset: AVURLAsset,
        seekSeconds: TimeInterval,
        targetSpeed: Float,
        isHLSToMasterAuto: Bool,
        controller: AVPlayerViewController
    ) {
        initialLoadObservation?.invalidate()
        initialLoadObservation = nil
        captionOverlayHost()?.clearCuesAndDisplay()

        let newItem = AVPlayerItem(asset: asset)
        newItem.externalMetadata = player?.currentItem?.externalMetadata ?? []
        if isHLSToMasterAuto {
            HLSPlaybackPreferences.applyPreferredMaximumResolution(nil, to: newItem)
        }
        newItem.preferredForwardBufferDuration = preferredBufferSeconds

        if let oldObs = endObserver {
            NotificationCenter.default.removeObserver(oldObs)
            endObserver = nil
        }
        if let obs = progressTimeObserver, let p = self.player {
            p.removeTimeObserver(obs)
            progressTimeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil

        let heldDuration: TimeInterval? = {
            guard let item = player?.currentItem else { return nil }
            let d = CMTimeGetSeconds(item.duration)
            return d.isFinite && d > 0 ? d : nil
        }()
        transportBar?.setHeldPlayhead(seekSeconds, duration: heldDuration)
        transportBar?.detach()

        // Create a fresh AVPlayer — replaceCurrentItem on tvOS with HLS
        // causes the new item to hang at status=0 indefinitely.
        let newPlayer = AVPlayer(playerItem: newItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        adoptPlayer(newPlayer, controller: controller)
        transportBar?.preferredPlaybackRate = targetSpeed
        transportBar?.attach(player: newPlayer)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }
        startProgressReporting()

        statusObservation = newItem.observe(\.status, options: [.initial, .new]) {
            [weak self, weak newPlayer] item, _ in
            DispatchQueue.main.async {
                guard let self, let newPlayer else { return }
                switch item.status {
                case .readyToPlay:
                    self.handleQualitySwapReady(
                        player: newPlayer,
                        item: item,
                        seekSeconds: seekSeconds,
                        targetSpeed: targetSpeed
                    )
                case .failed:
                    let err = item.error
                    PlaybackLog.log.error("resolution switch failed videoId=\(self.videoId, privacy: .public) \(err?.localizedDescription ?? "nil", privacy: .public)")
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    self.transportBar?.clearHeldPlayhead()
                    self.isSwitching = false
                    self.removeLoadingOverlay()
                default:
                    break
                }
            }
        }
    }

    private func setSpeed(_ speed: Float) {
        currentSpeed = speed
        transportBar?.preferredPlaybackRate = speed
        player?.defaultRate = speed
        if let player, player.rate > 0 {
            player.rate = speed
        }
    }

    // MARK: Loading overlay

    private func showLoadingOverlay(in controller: AVPlayerViewController) {
        removeLoadingOverlay(animated: false)
        transportBar?.setLoadingOverlayActive(true)
        PlayerLoadingOverlay.install(in: controller) { [weak self] wrapper in
            self?.loadingOverlay = wrapper
        }
    }

    private func removeLoadingOverlay(animated: Bool = true) {
        transportBar?.setLoadingOverlayActive(false)
        guard let overlay = loadingOverlay else { return }
        loadingOverlay = nil
        if animated {
            UIView.animate(withDuration: 0.25) {
                overlay.alpha = 0
            } completion: { _ in
                overlay.removeFromSuperview()
            }
        } else {
            overlay.removeFromSuperview()
        }
    }

    /// Shows the speed pill when a video starts at a non-1x default speed.
    private func announceStartingSpeedIfNeeded() {
        guard abs(currentSpeed - 1.0) > 0.001 else { return }
        transportBar?.showSpeedNotification(PlayerSettings.speedLabel(currentSpeed))
    }
}
