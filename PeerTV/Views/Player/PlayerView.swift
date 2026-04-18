import SwiftUI
import UIKit
import AVKit

struct PlayerView: View {
    let url: URL
    let resolutions: [ResolutionOption]
    let accessToken: String?
    @Environment(\.dismiss) private var dismiss

    init(url: URL, resolutions: [ResolutionOption] = [], accessToken: String? = nil) {
        self.url = url
        self.resolutions = resolutions
        self.accessToken = accessToken
    }

    var body: some View {
        AVPlayerViewControllerRepresentable(
            url: url,
            resolutions: resolutions,
            accessToken: accessToken,
            onDismiss: { dismiss() }
        )
        .ignoresSafeArea()
    }
}

// MARK: - UIViewControllerRepresentable

struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let url: URL
    let resolutions: [ResolutionOption]
    let accessToken: String?
    var onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let asset = Self.makeAsset(url: url, accessToken: accessToken, instanceBaseURL: nil)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        controller.player = player
        controller.delegate = context.coordinator
        context.coordinator.player = player
        context.coordinator.controller = controller

        controller.transportBarCustomMenuItems = context.coordinator.buildMenus()
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            resolutions: resolutions,
            initialURL: url,
            accessToken: accessToken,
            onDismiss: onDismiss
        )
    }

    /// Bearer is only attached for URLs on the PeerTube instance host. Object storage / CDNs
    /// often reject `Authorization: Bearer` (e.g. S3 expects SigV4), which breaks HLS.
    static func makeAsset(url: URL, accessToken: String?, instanceBaseURL: URL?) -> AVURLAsset {
        let bearer = Self.bearerTokenForPlayback(url: url, accessToken: accessToken, instanceBaseURL: instanceBaseURL)
        guard let bearer, !bearer.isEmpty else {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(bearer)"]
        ])
    }

    /// When `instanceBaseURL` is nil, Bearer is sent whenever `accessToken` is set (legacy behavior).
    static func bearerTokenForPlayback(url: URL, accessToken: String?, instanceBaseURL: URL?) -> String? {
        guard let accessToken, !accessToken.isEmpty else { return nil }
        guard let baseHost = instanceBaseURL?.host?.lowercased() else { return accessToken }
        guard let playbackHost = url.host?.lowercased() else { return accessToken }
        return playbackHost == baseHost ? accessToken : nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var player: AVPlayer?
        weak var controller: AVPlayerViewController?
        let onDismiss: (() -> Void)?

        private let resolutions: [ResolutionOption]
        private let autoURL: URL
        private let accessToken: String?
        private var currentLabel: String = "Auto"
        private var currentSpeed: Float = 1.0
        private var statusObservation: NSKeyValueObservation?
        private var loadingOverlay: UIView?
        private var isSwitching = false

        private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

        init(resolutions: [ResolutionOption], initialURL: URL, accessToken: String?, onDismiss: (() -> Void)?) {
            self.resolutions = resolutions
            self.autoURL = initialURL
            self.accessToken = accessToken
            self.onDismiss = onDismiss
        }

        // MARK: Delegate

        func playerViewControllerShouldDismiss(
            _ playerViewController: AVPlayerViewController
        ) -> Bool {
            true
        }

        func playerViewControllerDidEndDismissalTransition(
            _ playerViewController: AVPlayerViewController
        ) {
            playerViewController.player?.pause()
            statusObservation = nil
            removeLoadingOverlay()
            onDismiss?()
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

            return UIMenu(
                title: "Quality",
                image: UIImage(systemName: "sparkles.tv"),
                children: actions
            )
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
            return UIMenu(
                title: "Speed",
                image: UIImage(systemName: "gauge.with.dots.needle.67percent"),
                children: actions
            )
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

            let asset = AVPlayerViewControllerRepresentable.makeAsset(
                url: targetURL,
                accessToken: accessToken,
                instanceBaseURL: nil
            )
            let newItem = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: newItem)

            let tolerance = CMTime(seconds: 5, preferredTimescale: 600)

            statusObservation = newItem.observe(\.status, options: [.new]) {
                [weak self, weak player] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if item.status == .readyToPlay {
                        self.statusObservation?.invalidate()
                        self.statusObservation = nil
                        player?.rate = targetSpeed
                        player?.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) {
                            _ in
                            DispatchQueue.main.async {
                                self.isSwitching = false
                                self.removeLoadingOverlay()
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

        // MARK: Helpers

        private func speedLabel(_ speed: Float) -> String {
            if speed == 1.0 { return "Normal" }
            if speed == Float(Int(speed)) {
                return "\(Int(speed))x"
            }
            return "\(speed)x"
        }
    }
}
