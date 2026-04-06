import Combine
import SwiftUI

/// Named color themes (accent + optional color scheme). Persisted via `AppThemeStore`.
enum AppColorTheme: String, CaseIterable, Identifiable, Hashable {
    case system
    case midnight
    case ember
    case forest
    case rose
    case aurora

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .midnight: "Midnight"
        case .ember: "Ember"
        case .forest: "Forest"
        case .rose: "Rose"
        case .aurora: "Aurora"
        }
    }

    /// Primary accent for buttons, toggles, and focused controls.
    var accentColor: Color {
        switch self {
        case .system:
            return Color.accentColor
        case .midnight:
            return Color(red: 0.45, green: 0.68, blue: 1.0)
        case .ember:
            return Color(red: 1.0, green: 0.52, blue: 0.18)
        case .forest:
            return Color(red: 0.32, green: 0.82, blue: 0.48)
        case .rose:
            return Color(red: 1.0, green: 0.42, blue: 0.58)
        case .aurora:
            return Color(red: 0.58, green: 0.42, blue: 1.0)
        }
    }

    /// tvOS is mostly dark; themed presets keep dark UI with a distinct accent.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .midnight, .ember, .forest, .rose, .aurora: .dark
        }
    }
}

@MainActor
final class AppThemeStore: ObservableObject {
    static let storageKey = "PeerTV.appColorTheme"

    @Published var theme: AppColorTheme {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: Self.storageKey)
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let loaded = AppColorTheme(rawValue: raw) {
            theme = loaded
        } else {
            theme = .system
        }
    }
}

extension View {
    @ViewBuilder
    func peerTVAppTheme(_ theme: AppColorTheme) -> some View {
        switch theme {
        case .system:
            self
        default:
            if let scheme = theme.preferredColorScheme {
                self.tint(theme.accentColor).preferredColorScheme(scheme)
            } else {
                self.tint(theme.accentColor)
            }
        }
    }
}
