import SwiftUI
import UIKit

/// Hides and disables the real `UITabBar` while `locked` is true.
///
/// SwiftUI's `.toolbar(.hidden, for: .tabBar)` does not prevent the Siri Remote focus engine
/// from moving into tab items on tvOS. This touches the underlying `UITabBarController` instead.
struct TabBarControllerFocusLock: UIViewControllerRepresentable {
    var locked: Bool

    func makeUIViewController(context: Context) -> TabBarLockViewController {
        TabBarLockViewController()
    }

    func updateUIViewController(_ uiViewController: TabBarLockViewController, context: Context) {
        uiViewController.setLocked(locked)
    }

    final class TabBarLockViewController: UIViewController {
        private var locked = false

        func setLocked(_ value: Bool) {
            locked = value
            scheduleApply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleApply()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleApply()
        }

        private func scheduleApply() {
            DispatchQueue.main.async { [weak self] in
                self?.applyToTabBarIfNeeded()
            }
        }

        private func applyToTabBarIfNeeded() {
            guard let tabBar = resolveTabBar() else { return }
            let hide = locked
            tabBar.isHidden = hide
            tabBar.isUserInteractionEnabled = !hide
            tabBar.alpha = hide ? 0 : 1
        }

        private func resolveTabBar() -> UITabBar? {
            if let t = tabBarController?.tabBar { return t }
            if let root = view.window?.rootViewController {
                return Self.findTabBarController(startingAt: root)?.tabBar
            }
            return nil
        }

        private static func findTabBarController(startingAt vc: UIViewController) -> UITabBarController? {
            if let tab = vc as? UITabBarController { return tab }
            for child in vc.children {
                if let found = findTabBarController(startingAt: child) { return found }
            }
            if let presented = vc.presentedViewController {
                return findTabBarController(startingAt: presented)
            }
            return nil
        }
    }
}
