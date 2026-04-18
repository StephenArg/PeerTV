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
            presentPlayer(
                url: localURL,
                resolutions: [],
                accessToken: nil,
                videoId: videoId,
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
                presentPlayer(
                    url: playURL,
                    resolutions: video.resolutionOptions,
                    accessToken: accessToken,
                    videoId: videoId,
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

    // MARK: - Player presentation

    private func presentPlayer(
        url: URL,
        resolutions: [ResolutionOption],
        accessToken: String?,
        videoId: String,
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
        let player = AVPlayer(playerItem: item)

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.modalPresentationStyle = .fullScreen

        let coordinator = PlayerCoordinator(
            resolutions: resolutions,
            initialURL: url,
            accessToken: accessToken,
            player: player,
            controller: playerVC,
            videoId: videoId,
            apiClient: apiClient,
            playlistQueue: playlistQueue,
            isLocalDownload: isLocalDownload,
            instanceBaseURL: apiClient.baseURL
        ) { [weak self] in
            self?.isPresenting = false
        }
        playerVC.delegate = coordinator
        playerVC.transportBarCustomMenuItems = coordinator.buildMenus()

        objc_setAssociatedObject(
            playerVC, &AssociatedKeys.coordinator,
            coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        presenter.present(playerVC, animated: true) {
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
    private var currentLabel: String = "Auto"
    private var currentSpeed: Float = 1.0
    private var statusObservation: NSKeyValueObservation?
    private var initialLoadObservation: NSKeyValueObservation?
    private var loadingOverlay: UIView?
    private var isSwitching = false
    private var endObserver: Any?
    private var progressTimeObserver: Any?
    private let isLocalDownload: Bool

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private static let watchReportInterval: Double = 30

    init(resolutions: [ResolutionOption], initialURL: URL, accessToken: String?,
         player: AVPlayer, controller: AVPlayerViewController,
         videoId: String, apiClient: PeerTubeAPIClient?,
         playlistQueue: PlaylistPlaybackQueue?,
         isLocalDownload: Bool,
         instanceBaseURL: URL?,
         onDismiss: @escaping () -> Void) {
        self.resolutions = resolutions
        self.autoURL = initialURL
        self.accessToken = accessToken
        self.player = player
        self.controller = controller
        self.videoId = videoId
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
                    if let vc = self.controller {
                        let alert = UIAlertController(title: "Playback failed", message: message, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                            self?.controller?.dismiss(animated: true) {
                                self?.performDismissCleanup()
                            }
                        })
                        vc.present(alert, animated: true)
                    } else {
                        self.controller?.dismiss(animated: true) { [weak self] in
                            self?.performDismissCleanup()
                        }
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
        controller?.dismiss(animated: true) { [weak self] in
            self?.performDismissCleanup()
        }
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
            currentLabel = "Auto"

            let asset = AVPlayerViewControllerRepresentable.makeAsset(
                url: url,
                accessToken: nextQueue.accessToken,
                instanceBaseURL: nextQueue.apiClient.baseURL
            )
            let newItem = AVPlayerItem(asset: asset)

            if let obs = progressTimeObserver, let p = self.player {
                p.removeTimeObserver(obs)
                progressTimeObserver = nil
            }

            let newPlayer = AVPlayer(playerItem: newItem)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            self.player = newPlayer
            controller.player = newPlayer

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
                                self.refreshMenus()
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
                        self.controller?.dismiss(animated: true) {
                            self.performDismissCleanup()
                        }
                    }
                }
            }
        } catch {
            PlaybackLog.log.error("playlist transition videoDetail failed videoId=\(nextVideoId, privacy: .public) \(error.localizedDescription, privacy: .public)")
            isSwitching = false
            removeLoadingOverlay()
            controller.dismiss(animated: true) { [weak self] in
                self?.performDismissCleanup()
            }
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
        true
    }

    func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        performDismissCleanup()
    }

    private func performDismissCleanup() {
        guard !didCallDismiss else { return }
        didCallDismiss = true
        reportCurrentTime()
        player?.pause()
        statusObservation = nil
        removeLoadingOverlay()
        NotificationCenter.default.post(
            name: .peerTVPlayerDismissed,
            object: nil,
            userInfo: ["videoId": videoId]
        )
        onDismiss()
    }

    // MARK: Menus

    func buildMenus() -> [UIMenuElement] {
        var menus: [UIMenuElement] = []
        if let resMenu = buildResolutionMenu() {
            menus.append(resMenu)
        }
        menus.append(buildSpeedMenu())
        return menus
    }

    private func buildResolutionMenu() -> UIMenu? {
        guard !resolutions.isEmpty else { return nil }

        var actions: [UIAction] = []
        actions.append(UIAction(
            title: "Auto",
            state: currentLabel == "Auto" ? .on : .off
        ) { [weak self] _ in
            self?.switchItem(to: nil)
        })

        for option in resolutions {
            actions.append(UIAction(
                title: option.label,
                state: currentLabel == option.label ? .on : .off
            ) { [weak self] _ in
                self?.switchItem(to: option)
            })
        }

        return UIMenu(title: "Quality", image: UIImage(systemName: "sparkles.tv"), children: actions)
    }

    private func buildSpeedMenu() -> UIMenu {
        let actions = Self.speeds.map { speed in
            UIAction(
                title: speedLabel(speed),
                state: currentSpeed == speed ? .on : .off
            ) { [weak self] _ in
                self?.setSpeed(speed)
            }
        }
        return UIMenu(title: "Speed", image: UIImage(systemName: "gauge.with.dots.needle.67percent"), children: actions)
    }

    // MARK: Actions

    private func switchItem(to option: ResolutionOption?) {
        guard let player, let controller, !isSwitching else { return }

        let seekTime = player.currentTime()
        let targetSpeed = currentSpeed
        let targetURL = option?.url ?? autoURL

        currentLabel = option?.label ?? "Auto"
        isSwitching = true
        statusObservation?.invalidate()
        statusObservation = nil

        player.pause()
        showLoadingOverlay(in: controller)

        if targetURL.pathExtension.lowercased() == "m3u8", let apiClient {
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
                self.refreshMenus()
            }
            refreshMenus()
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
            refreshMenus()
        }
    }

    private func performAssetSwap(
        asset: AVURLAsset, seekTime: CMTime, targetSpeed: Float,
        controller: AVPlayerViewController
    ) {
        initialLoadObservation?.invalidate()
        initialLoadObservation = nil

        let newItem = AVPlayerItem(asset: asset)

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

        // Create a fresh AVPlayer — replaceCurrentItem on tvOS with HLS
        // causes the new item to hang at status=0 indefinitely.
        let newPlayer = AVPlayer(playerItem: newItem)
        self.player = newPlayer
        controller.player = newPlayer

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }
        startProgressReporting()

        let tolerance = CMTime(seconds: 5, preferredTimescale: 600)

        statusObservation = newItem.observe(\.status, options: [.new]) {
            [weak self, weak newPlayer] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .readyToPlay {
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    newPlayer?.rate = targetSpeed
                    newPlayer?.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) {
                        finished in
                        DispatchQueue.main.async {
                            self.isSwitching = false
                            self.removeLoadingOverlay()
                        }
                    }
                } else if item.status == .failed {
                    let err = item.error
                    PlaybackLog.log.error("performAssetSwap item failed videoId=\(self.videoId, privacy: .public) \(err?.localizedDescription ?? "nil", privacy: .public)")
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
        refreshMenus()
    }

    private func refreshMenus() {
        controller?.transportBarCustomMenuItems = buildMenus()
    }

    // MARK: Loading overlay

    private func showLoadingOverlay(in controller: AVPlayerViewController) {
        removeLoadingOverlay(animated: false)
        PlayerLoadingOverlay.install(in: controller) { [weak self] wrapper in
            self?.loadingOverlay = wrapper
        }
    }

    private func removeLoadingOverlay(animated: Bool = true) {
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
