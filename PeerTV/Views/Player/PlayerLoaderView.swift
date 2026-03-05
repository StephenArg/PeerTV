import UIKit
import AVKit
import SwiftUI

// MARK: - PlayerPresenter

/// Presents AVPlayerViewController directly via UIKit — no SwiftUI fullScreenCover
/// in between. This eliminates the double-transition flash and double-back-press issue.
@MainActor
final class PlayerPresenter {
    static let shared = PlayerPresenter()

    private var isPresenting = false
    private var loadingOverlay: UIView?

    func play(videoId: String, apiClient: PeerTubeAPIClient, accessToken: String?) {
        guard !isPresenting else { return }
        isPresenting = true

        guard let window = Self.keyWindow else {
            isPresenting = false
            return
        }

        showLoadingOverlay(on: window)

        Task {
            do {
                let data = try await apiClient.rawRequest(.videoDetail(id: videoId))
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                decoder.dateDecodingStrategy = .iso8601
                let video = try decoder.decode(Video.self, from: data)

                guard let url = video.hlsPlaylistURL ?? video.playbackURL else {
                    removeLoadingOverlay()
                    isPresenting = false
                    return
                }

                removeLoadingOverlay()
                presentPlayer(
                    url: url,
                    resolutions: video.resolutionOptions,
                    accessToken: accessToken,
                    videoId: videoId,
                    apiClient: apiClient
                )
            } catch {
                removeLoadingOverlay()
                isPresenting = false
            }
        }
    }

    // MARK: - Player presentation

    private func presentPlayer(
        url: URL,
        resolutions: [ResolutionOption],
        accessToken: String?,
        videoId: String,
        apiClient: PeerTubeAPIClient
    ) {
        guard let root = Self.keyWindow?.rootViewController else {
            isPresenting = false
            return
        }

        let presenter = Self.topViewController(from: root)

        let asset = AVPlayerViewControllerRepresentable.makeAsset(url: url, token: accessToken)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)

        let playerVC = AVPlayerViewController()
        playerVC.player = player

        let coordinator = PlayerCoordinator(
            resolutions: resolutions,
            initialURL: url,
            accessToken: accessToken,
            player: player,
            controller: playerVC,
            videoId: videoId,
            apiClient: apiClient
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

    private let resolutions: [ResolutionOption]
    private let autoURL: URL
    private let accessToken: String?
    private let videoId: String
    private let apiClient: PeerTubeAPIClient?
    private var currentLabel: String = "Auto"
    private var currentSpeed: Float = 1.0
    private var statusObservation: NSKeyValueObservation?
    private var loadingOverlay: UIView?
    private var isSwitching = false
    private var endObserver: Any?
    private var progressTimeObserver: Any?

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private static let watchReportInterval: Double = 30

    init(resolutions: [ResolutionOption], initialURL: URL, accessToken: String?,
         player: AVPlayer, controller: AVPlayerViewController,
         videoId: String, apiClient: PeerTubeAPIClient?,
         onDismiss: @escaping () -> Void) {
        self.resolutions = resolutions
        self.autoURL = initialURL
        self.accessToken = accessToken
        self.player = player
        self.controller = controller
        self.videoId = videoId
        self.apiClient = apiClient
        self.onDismiss = onDismiss
        super.init()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.reportCurrentTime()
            self?.controller?.dismiss(animated: true) {
                self?.performDismissCleanup()
            }
        }

        reportCurrentTime()
        startProgressReporting()
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let progressTimeObserver, let player { player.removeTimeObserver(progressTimeObserver) }
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

        let asset = AVPlayerViewControllerRepresentable.makeAsset(url: targetURL, token: accessToken)
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = 10
        player.automaticallyWaitsToMinimizeStalling = true

        player.replaceCurrentItem(with: newItem)

        if let oldObs = endObserver {
            NotificationCenter.default.removeObserver(oldObs)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            self?.reportCurrentTime()
            self?.controller?.dismiss(animated: true) {
                self?.performDismissCleanup()
            }
        }

        let tolerance = CMTime(seconds: 2, preferredTimescale: 600)

        statusObservation = newItem.observe(\.status, options: [.new]) {
            [weak self, weak player] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .readyToPlay {
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    player?.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) {
                        [weak self, weak player] finished in
                        guard finished else { return }
                        DispatchQueue.main.async {
                            player?.rate = targetSpeed
                            self?.isSwitching = false
                            self?.removeLoadingOverlay()
                        }
                    }
                } else if item.status == .failed {
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    self.isSwitching = false
                    self.removeLoadingOverlay()
                }
            }
        }

        refreshMenus()
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
        guard let overlayContainer = controller.contentOverlayView else { return }

        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.backgroundColor = .clear
        overlayContainer.addSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.topAnchor.constraint(equalTo: overlayContainer.topAnchor),
            wrapper.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
            wrapper.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
            wrapper.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor)
        ])

        if let snapshot = controller.view.snapshotView(afterScreenUpdates: false) {
            snapshot.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(snapshot)
            NSLayoutConstraint.activate([
                snapshot.topAnchor.constraint(equalTo: wrapper.topAnchor),
                snapshot.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                snapshot.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                snapshot.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
            ])
        }

        let scrim = UIView()
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        wrapper.addSubview(scrim)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: wrapper.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        wrapper.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
        ])

        loadingOverlay = wrapper
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
