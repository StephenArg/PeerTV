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

// MARK: - PlayerPresenter

/// Presents AVPlayerViewController directly via UIKit — no SwiftUI fullScreenCover
/// in between. This eliminates the double-transition flash and double-back-press issue.
@MainActor
final class PlayerPresenter {
    static let shared = PlayerPresenter()

    private var isPresenting = false
    private var loadingOverlay: UIView?

    func play(
        videoId: String,
        apiClient: PeerTubeAPIClient,
        accessToken: String?,
        playlistQueue: PlaylistPlaybackQueue? = nil
    ) {
        guard !isPresenting else { return }
        isPresenting = true

        guard let window = Self.keyWindow else {
            PlaybackLog.log.error("play aborted: no key window videoId=\(videoId, privacy: .public)")
            isPresenting = false
            return
        }

        if let localURL = DownloadManager.shared.localFileURL(for: videoId) {
            let localTitle = DownloadManager.shared.downloadedVideos.first(where: { $0.videoId == videoId })?.name ?? ""
            // Local downloads have no resolution choice; play the file as-is.
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
                isLocalDownload: true
            )
            return
        }

        showLoadingOverlay(on: window)
        PlaybackLog.log.notice("loading video detail videoId=\(videoId, privacy: .public)")

        Task {
            do {
                let data = try await apiClient.rawRequest(.videoDetail(id: videoId))
                PlaybackLog.log.notice("videoDetail OK bytes=\(data.count) videoId=\(videoId, privacy: .public)")
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                decoder.dateDecodingStrategy = .iso8601
                let video = try decoder.decode(Video.self, from: data)

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
                    apiClient: apiClient,
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
                // Inject HLS token on the chosen variant URL too (the master URL was already
                // token-injected above, but a resolution-specific `.m3u8` needs its own query).
                let startURL: URL
                if pick.url == playURL {
                    startURL = pick.url
                } else {
                    startURL = await Self.urlWithHLSTokenIfNeeded(
                        url: pick.url,
                        videoId: videoId,
                        apiClient: apiClient,
                        accessToken: accessToken
                    )
                }

                presentPlayer(
                    url: startURL,
                    autoURL: playURL,
                    initialLabel: pick.label,
                    resolutions: resolutionOptions,
                    accessToken: accessToken,
                    videoId: videoId,
                    title: video.name ?? "",
                    apiClient: apiClient,
                    playlistQueue: playlistQueue,
                    isLocalDownload: false
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

    /// Chooses which URL the player should start from, based on the user's default-resolution
    /// setting. Returns both the URL to play *and* the Quality menu label that matches it.
    ///
    /// - Exact match on the requested resolution → use that variant.
    /// - No exact match → next lower resolution available ("play the next largest quality").
    /// - No lower resolution either → fall back to Auto (the master playlist).
    ///
    /// For local downloads and non-HLS / non-variant sources the fallback is the passed-in
    /// `masterURL` unchanged, with the `"Auto"` label.
    static func chooseInitialPlayback(
        resolutions: [ResolutionOption],
        masterURL: URL,
        defaultResolution: DefaultResolution
    ) -> (url: URL, label: String) {
        guard defaultResolution != .auto else { return (masterURL, "Auto") }
        let target = defaultResolution.rawValue
        if let exact = resolutions.first(where: { $0.resolutionId == target }) {
            return (exact.url, exact.label)
        }
        // "Next largest quality" = largest resolution id strictly less than the target.
        if let nextLower = resolutions
            .filter({ $0.resolutionId < target })
            .max(by: { $0.resolutionId < $1.resolutionId })
        {
            return (nextLower.url, nextLower.label)
        }
        return (masterURL, "Auto")
    }

    // MARK: - Player presentation

    private func presentPlayer(
        url: URL,
        autoURL: URL,
        initialLabel: String,
        resolutions: [ResolutionOption],
        accessToken: String?,
        videoId: String,
        title: String,
        apiClient: PeerTubeAPIClient,
        playlistQueue: PlaylistPlaybackQueue?,
        isLocalDownload: Bool
    ) {
        guard let root = Self.keyWindow?.rootViewController else {
            PlaybackLog.log.error("presentPlayer: no root VC videoId=\(videoId, privacy: .public)")
            isPresenting = false
            return
        }

        let presenter = Self.topViewController(from: root)

        let asset = AVPlayerViewControllerRepresentable.makeAsset(
            url: url,
            accessToken: accessToken,
            instanceBaseURL: apiClient.baseURL
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = PlayerSettings.bufferCap.preferredBufferSeconds
        let player = AVPlayer(playerItem: item)

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.modalPresentationStyle = .fullScreen
        playerVC.playbackControlsIncludeTransportBar = false
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
            title: title,
            apiClient: apiClient,
            playlistQueue: playlistQueue,
            isLocalDownload: isLocalDownload,
            instanceBaseURL: apiClient.baseURL
        ) { [weak self] in
            self?.isPresenting = false
        }
        playerVC.delegate = coordinator

        // Wrap AVPlayerViewController in a container so focus routes to the overlay reliably.
        let container = PlayerContainerViewController(
            playerViewController: playerVC,
            overlayRoot: coordinator.transportBarRootView
        )
        coordinator.containerController = container
        container.onDismissed = { [weak coordinator] in
            coordinator?.performDismissCleanup()
        }
        // Let the container consult the coordinator before dismissing on Menu/Back: a
        // pending visual-scrub commit is cancelled in place instead of closing the player.
        container.shouldConsumeMenuPress = { [weak coordinator] in
            coordinator?.handleMenuPressIfNeeded() ?? false
        }

        objc_setAssociatedObject(
            container, &AssociatedKeys.coordinator,
            coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        presenter.present(container, animated: true) {
            PlaybackLog.log.notice("AVPlayerViewController on-screen videoId=\(videoId, privacy: .public)")
            player.play()
        }
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
final class PlayerCoordinator: NSObject, AVPlayerViewControllerDelegate {
    weak var player: AVPlayer?
    weak var controller: AVPlayerViewController?
    weak var containerController: UIViewController?
    private let onDismiss: () -> Void
    private var didCallDismiss = false

    private var resolutions: [ResolutionOption]
    private var autoURL: URL
    private let accessToken: String?
    private var videoId: String
    private let apiClient: PeerTubeAPIClient?
    /// Snapshot from `apiClient.baseURL` at presentation time (avoids MainActor isolation in delegate methods).
    private let instanceBaseURL: URL?
    private var playlistQueue: PlaylistPlaybackQueue?
    private var currentLabel: String
    private var currentSpeed: Float = 1.0
    private var statusObservation: NSKeyValueObservation?
    private var initialLoadObservation: NSKeyValueObservation?
    private var loadingOverlay: UIView?
    private var isSwitching = false
    private var endObserver: Any?
    private var progressTimeObserver: Any?
    private let isLocalDownload: Bool
    private var transportBar: TransportBarController?
    private var title: String

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private static let watchReportInterval: Double = 30

    init(resolutions: [ResolutionOption], autoURL: URL, initialLabel: String, accessToken: String?,
         player: AVPlayer, controller: AVPlayerViewController,
         videoId: String, title: String, apiClient: PeerTubeAPIClient?,
         playlistQueue: PlaylistPlaybackQueue?,
         isLocalDownload: Bool,
         instanceBaseURL: URL?,
         onDismiss: @escaping () -> Void) {
        self.resolutions = resolutions
        self.autoURL = autoURL
        self.currentLabel = initialLabel
        self.accessToken = accessToken
        self.player = player
        self.controller = controller
        self.videoId = videoId
        self.title = title
        self.apiClient = apiClient
        self.instanceBaseURL = instanceBaseURL
        self.playlistQueue = playlistQueue
        self.isLocalDownload = isLocalDownload
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

        transportBar = TransportBarController(
            showsQualityButton: !resolutions.isEmpty,
            title: title,
            onQualityTapped: { [weak self] in self?.presentQualityMenu() },
            onSpeedTapped: { [weak self] in self?.presentSpeedMenu() }
        )
        transportBar?.attach(player: player)
        fetchStoryboards(for: videoId)
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
                  let sheetURL = await storyboardImageURL(path: storyboard.storyboardPath, apiClient: apiClient)
            else { return }

            let (imageData, _) = try await URLSession.shared.data(from: sheetURL)
            guard let sheet = UIImage(data: imageData) else { return }

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

    deinit {
        initialLoadObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
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

    // MARK: - End of item / playlist autoplay

    private func handlePlaybackEnded() {
        reportCurrentTime()
        if let queue = playlistQueue,
           queue.autoplayEnabled,
           queue.currentIndex + 1 < queue.videoIds.count {
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
            let data = try await nextQueue.apiClient.rawRequest(.videoDetail(id: nextVideoId))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let video = try decoder.decode(Video.self, from: data)

            guard var url = video.hlsPlaylistURL ?? video.playbackURL else {
                throw URLError(.badURL)
            }

            url = await PlayerPresenter.urlWithHLSTokenIfNeeded(
                url: url,
                videoId: nextVideoId,
                apiClient: nextQueue.apiClient,
                accessToken: nextQueue.accessToken
            )

            if let oldObs = endObserver {
                NotificationCenter.default.removeObserver(oldObs)
            }
            endObserver = nil
            statusObservation?.invalidate()
            statusObservation = nil

            videoId = nextVideoId
            playlistQueue = nextQueue
            resolutions = video.resolutionOptions
            autoURL = url
            // Apply the default-resolution setting to the next item too.
            let pick = PlayerPresenter.chooseInitialPlayback(
                resolutions: resolutions,
                masterURL: url,
                defaultResolution: PlayerSettings.defaultResolution
            )
            let startURL: URL
            if pick.url == url {
                startURL = url
            } else {
                startURL = await PlayerPresenter.urlWithHLSTokenIfNeeded(
                    url: pick.url,
                    videoId: nextVideoId,
                    apiClient: nextQueue.apiClient,
                    accessToken: nextQueue.accessToken
                )
            }
            currentLabel = pick.label
            title = video.name ?? ""
            transportBar?.setTitle(title)
            // Drop stale storyboard; `fetchStoryboards` below re-installs one for the new item.
            transportBar?.storyboardProvider = nil
            fetchStoryboards(for: nextVideoId)

            let asset = AVPlayerViewControllerRepresentable.makeAsset(
                url: startURL,
                accessToken: nextQueue.accessToken,
                instanceBaseURL: nextQueue.apiClient.baseURL
            )
            let newItem = AVPlayerItem(asset: asset)
            newItem.preferredForwardBufferDuration = PlayerSettings.bufferCap.preferredBufferSeconds

            if let obs = progressTimeObserver, let p = self.player {
                p.removeTimeObserver(obs)
                progressTimeObserver = nil
            }

            transportBar?.detach()

            let newPlayer = AVPlayer(playerItem: newItem)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            self.player = newPlayer
            controller.player = newPlayer
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

    // MARK: Watch history reporting

    private func startProgressReporting() {
        let interval = CMTime(seconds: Self.watchReportInterval, preferredTimescale: 600)
        progressTimeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] _ in
            self?.reportCurrentTime()
        }
    }

    private func reportCurrentTime() {
        guard let player, let apiClient else { return }
        let raw = CMTimeGetSeconds(player.currentTime())
        guard raw.isFinite else { return }
        let seconds = Int(raw)
        Task { [videoId] in
            _ = try? await apiClient.rawRequest(.watchVideo(id: videoId, currentTime: max(0, seconds)))
        }
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

    func performDismissCleanup() {
        guard !didCallDismiss else { return }
        didCallDismiss = true
        reportCurrentTime()
        player?.pause()
        statusObservation = nil
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
        for speed in Self.speeds {
            let isCurrent = abs(speed - currentSpeed) < 0.001
            let action = UIAlertAction(title: Self.menuTitle(speedLabel(speed), selected: isCurrent), style: .default) { [weak self] _ in
                self?.setSpeed(speed)
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

        let seekTime = player.currentTime()
        let targetSpeed = currentSpeed
        let targetURL = option?.url ?? autoURL
        let label = option?.label ?? "Auto"
        let ext = targetURL.pathExtension.lowercased()

        currentLabel = label
        isSwitching = true
        statusObservation?.invalidate()
        statusObservation = nil

        player.pause()
        showLoadingOverlay(in: controller)

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
                    asset: asset, seekTime: seekTime, targetSpeed: targetSpeed,
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
                asset: asset, seekTime: seekTime, targetSpeed: targetSpeed,
                controller: controller
            )
        }
    }

    private func performAssetSwap(
        asset: AVURLAsset, seekTime: CMTime, targetSpeed: Float,
        controller: AVPlayerViewController
    ) {
        initialLoadObservation?.invalidate()
        initialLoadObservation = nil

        let tolerance = CMTime(seconds: 5, preferredTimescale: 600)

        let newItem = AVPlayerItem(asset: asset)
        // Mid-stream resolution switches prefer a *small* preroll so playback restarts quickly;
        // the full user-selected buffer cap would force AVFoundation to fetch many minutes of
        // the new target playlist before resuming. Keep a tight 8 s preroll here, then let
        // AVPlayer grow the buffer to the user's cap during normal playback (set via the
        // `.readyToPlay` branch below).
        newItem.preferredForwardBufferDuration = 8

        // Pre-install the seek directly on the `AVPlayerItem` before it is ever attached to a player.
        // Without this, AVPlayer begins buffering from `currentTime = 0` during the unknown→readyToPlay
        // preroll and then throws ~52 s of data away the moment we seek to e.g. t=570 s. Queuing the
        // seek here tells AVFoundation the real playhead target, so the very first segments it fetches
        // are at the seek destination.
        newItem.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance, completionHandler: nil)

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

        transportBar?.detach()

        // Create a fresh AVPlayer — replaceCurrentItem on tvOS with HLS
        // causes the new item to hang at status=0 indefinitely.
        let newPlayer = AVPlayer(playerItem: newItem)
        self.player = newPlayer
        controller.player = newPlayer
        transportBar?.attach(player: newPlayer)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }
        startProgressReporting()

        statusObservation = newItem.observe(\.status, options: [.new]) {
            [weak self, weak newPlayer] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .readyToPlay {
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    // Let the buffer grow to the user-selected cap now that the switch preroll
                    // is done. During preroll we used a tight 8 s so playback resumed quickly.
                    item.preferredForwardBufferDuration = PlayerSettings.bufferCap.preferredBufferSeconds
                    // No explicit second seek — the item was pre-seeked before the player was attached,
                    // so its first buffered range is already at the target time. Just set the rate to
                    // start playback.
                    newPlayer?.rate = targetSpeed
                    self.isSwitching = false
                    self.removeLoadingOverlay()
                } else if item.status == .failed {
                    let err = item.error
                    PlaybackLog.log.error("resolution switch failed videoId=\(self.videoId, privacy: .public) \(err?.localizedDescription ?? "nil", privacy: .public)")
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    self.isSwitching = false
                    self.removeLoadingOverlay()
                }
            }
        }
    }

    private func setSpeed(_ speed: Float) {
        currentSpeed = speed
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

    private func speedLabel(_ speed: Float) -> String {
        if speed == 1.0 { return "Normal" }
        if speed == Float(Int(speed)) { return "\(Int(speed))x" }
        return "\(speed)x"
    }
}
