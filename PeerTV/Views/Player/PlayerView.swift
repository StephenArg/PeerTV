import SwiftUI
import UIKit
import AVKit

struct PlayerView: View {
    let url: URL
    let resolutions: [ResolutionOption]
    let accessToken: String?
    let title: String
    @Environment(\.dismiss) private var dismiss

    init(url: URL, resolutions: [ResolutionOption] = [], accessToken: String? = nil, title: String = "") {
        self.url = url
        self.resolutions = resolutions
        self.accessToken = accessToken
        self.title = title
    }

    var body: some View {
        AVPlayerViewControllerRepresentable(
            url: url,
            resolutions: resolutions,
            accessToken: accessToken,
            title: title,
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
    var title: String = ""
    var onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = AVPlayerViewController()
        controller.playbackControlsIncludeTransportBar = false
        if TransportBarConfiguration.requiresHidingAllSystemPlaybackControls {
            controller.showsPlaybackControls = false
        }

        let asset = Self.makeAsset(url: url, accessToken: accessToken, instanceBaseURL: nil)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = PlayerSettings.bufferCap.preferredBufferSeconds
        let player = AVPlayer(playerItem: item)
        controller.player = player
        controller.delegate = context.coordinator
        context.coordinator.player = player
        context.coordinator.controller = controller
        context.coordinator.setupTransportBar()

        let container = PlayerContainerViewController(
            playerViewController: controller,
            overlayRoot: context.coordinator.transportBarRootView
        )
        context.coordinator.container = container
        context.coordinator.wireCaptionTimeUpdates(to: container)
        container.onPlayPausePress = { [weak coordinator = context.coordinator] in
            coordinator?.handlePlayPausePress()
        }

        player.play()
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            resolutions: resolutions,
            initialURL: url,
            accessToken: accessToken,
            title: title,
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
        weak var container: UIViewController?
        let onDismiss: (() -> Void)?

        private let resolutions: [ResolutionOption]
        private let autoURL: URL
        private let accessToken: String?
        private let title: String
        private var currentLabel: String = "Auto"
        private var currentSpeed: Float = 1.0
        /// Playback rate captured when the temporary touch-hold boost latched (non-nil =>
        /// boost is active). Restored on finger-lift. See `PlayerCoordinator` for the full
        /// rationale — short version: use live `player.rate` so the restore matches what the
        /// user was actually hearing.
        private var rateBeforeTouchHoldBoost: Float?
        private var statusObservation: NSKeyValueObservation?
        private var loadingOverlay: UIView?
        private var isSwitching = false
        private var transportBar: TransportBarController?

        var transportBarRootView: TransportBarRootView {
            if let bar = transportBar { return bar.rootView }
            // Transport bar is created on first access (before container is built).
            let bar = TransportBarController(
                showsQualityButton: !resolutions.isEmpty,
                showsSkipNextButton: false,
                title: title,
                onQualityTapped: { [weak self] in self?.presentQualityMenu() },
                onSpeedTapped: { [weak self] in self?.presentSpeedMenu() },
                onSkipNextTapped: nil
            )
            transportBar = bar
            return bar.rootView
        }

        private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

        init(resolutions: [ResolutionOption], initialURL: URL, accessToken: String?, title: String, onDismiss: (() -> Void)?) {
            self.resolutions = resolutions
            self.autoURL = initialURL
            self.accessToken = accessToken
            self.title = title
            self.onDismiss = onDismiss
        }

        func setupTransportBar() {
            guard let player else { return }
            if transportBar == nil {
                transportBar = TransportBarController(
                    showsQualityButton: !resolutions.isEmpty,
                    showsSkipNextButton: false,
                    title: title,
                    onQualityTapped: { [weak self] in self?.presentQualityMenu() },
                    onSpeedTapped: { [weak self] in self?.presentSpeedMenu() },
                    onCaptionsTapped: nil,
                    onSkipNextTapped: nil,
                    onSpeedHold: { [weak self] in self?.toggleSpeedHold() },
                    onTouchHoldBegan: { [weak self] in self?.startTouchHoldBoost() },
                    onTouchHoldEnded: { [weak self] in self?.endTouchHoldBoost() }
                )
            }
            transportBar?.attach(player: player)
        }

        /// Hooks periodic playback time into the caption overlay (SwiftUI player has no PeerTube captions).
        func wireCaptionTimeUpdates(to container: PlayerContainerViewController) {
            transportBar?.onTimeUpdate = { [weak container] t in
                container?.captionOverlay.setCurrentTime(t)
            }
        }

        func handlePlayPausePress() {
            transportBar?.handlePlayPausePress()
        }

        /// Toggles the playback rate between 2x and 1x when the user long-presses the
        /// touchpad click (`.select`). Mirrors the behavior in `PlayerCoordinator` (see
        /// comments there) — always applies the rate (even if paused, so the gesture gives
        /// instant feedback), updates `currentSpeed` so resolution swaps reapply the new
        /// rate, and reads the live `player.rate` instead of the stored `currentSpeed`
        /// since the latter can go stale after a tap-pause-then-tap-play cycle (AVPlayer's
        /// `play()` always snaps rate back to 1.0).
        private func toggleSpeedHold() {
            let fast: Float = 2.0
            let currentRate = player?.rate ?? 1.0
            let newSpeed: Float = abs(currentRate - fast) < 0.001 ? 1.0 : fast
            currentSpeed = newSpeed
            player?.rate = newSpeed
            transportBar?.showSpeedNotification("\(Int(newSpeed))x")
        }

        /// Touchpad-hold temporary 2x boost. Mirrors the implementation in
        /// `PlayerCoordinator.startTouchHoldBoost`; see there for the full rationale. Skipped
        /// while paused so the user's scrub-while-paused flow (pan gesture) is unaffected.
        private func startTouchHoldBoost() {
            guard let player else { return }
            guard player.timeControlStatus != .paused else { return }
            guard rateBeforeTouchHoldBoost == nil else { return }

            rateBeforeTouchHoldBoost = player.rate
            player.rate = 2.0
        }

        /// Releases the temporary boost started by `startTouchHoldBoost`. Leaves the player
        /// alone if something paused it during the boost (we don't want to yank playback back
        /// to 2x against the user's explicit pause action).
        private func endTouchHoldBoost() {
            guard let saved = rateBeforeTouchHoldBoost else { return }
            rateBeforeTouchHoldBoost = nil
            guard let player, player.rate > 0 else { return }
            player.rate = saved
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
            transportBar?.tearDown()
            transportBar = nil
            removeLoadingOverlay()
            onDismiss?()
        }

        // MARK: Menus (action sheets)

        private func presentQualityMenu() {
            guard let vc = container ?? controller, !resolutions.isEmpty else { return }
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
            guard let vc = container ?? controller else { return }
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
            newItem.preferredForwardBufferDuration = PlayerSettings.bufferCap.preferredBufferSeconds
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
