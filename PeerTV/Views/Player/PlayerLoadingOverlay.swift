import UIKit
import AVKit

/// Full-screen scrim + spinner for `AVPlayerViewController` without using `snapshotView`.
/// Snapshots force synchronous layout and can touch AVKit’s internal `UITextView` (TextKit 1 warnings).
/// Installation is deferred until after layout so `contentOverlayView` is not width 0 (avoids Auto Layout
/// conflicts with `_AVFocusContainerView` / transport bar during transitions).
enum PlayerLoadingOverlay {
    static func install(in controller: AVPlayerViewController, onComplete: @escaping (UIView) -> Void) {
        DispatchQueue.main.async {
            controller.view.layoutIfNeeded()
            guard let overlayContainer = controller.contentOverlayView else { return }
            if overlayContainer.bounds.width < 1 {
                DispatchQueue.main.async {
                    Self.installWhenLaidOut(controller: controller, onComplete: onComplete)
                }
            } else {
                Self.installWhenLaidOut(controller: controller, onComplete: onComplete)
            }
        }
    }

    private static func installWhenLaidOut(controller: AVPlayerViewController, onComplete: @escaping (UIView) -> Void) {
        controller.view.layoutIfNeeded()
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

        onComplete(wrapper)
    }
}
