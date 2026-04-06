import Combine
import SwiftUI

/// Shared with `MainTabView` so playlist reorder can block switching away from the Playlists tab.
@MainActor
final class PlaylistEditCoordinator: ObservableObject {
    @Published var isRepositioning = false
}
