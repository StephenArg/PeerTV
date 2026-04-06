import SwiftUI
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
        let asset = Self.makeAsset(url: url, token: accessToken)
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

    static func makeAsset(url: URL, token: String?) -> AVURLAsset {
        guard let token, !token.isEmpty else {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]
        ])
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

            let asset = AVPlayerViewControllerRepresentable.makeAsset(url: targetURL, token: accessToken)
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
