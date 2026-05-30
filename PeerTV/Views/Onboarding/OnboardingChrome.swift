import SwiftUI

// MARK: - Background

struct OnboardingBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.05, blue: 0.12),
                Color(red: 0.08, green: 0.10, blue: 0.22),
                Color.accentColor.opacity(0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Header

struct OnboardingHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 24, y: 8)

            Text("PeerTV")
                .font(.largeTitle)
                .bold()

            Text(title)
                .font(.title2)
                .bold()

            Text(subtitle)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Form chrome

struct OnboardingFormCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 20) {
            content()
        }
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
    }
}

struct OnboardingTextFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func onboardingTextFieldStyle() -> some View {
        modifier(OnboardingTextFieldStyle())
    }
}

/// Fixed fill/label colors so tvOS focus does not paint accent-on-accent (invisible text).
enum OnboardingPrimaryButtonColors {
    static let fill = Color(red: 0.30, green: 0.52, blue: 0.96)
    static let label = Color.white
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingPrimaryButtonBody(configuration: configuration)
    }
}

/// Separate `View` so `@Environment(\.isFocused)` updates reliably on tvOS (not always true inside `ButtonStyle.makeBody`).
private struct OnboardingPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(OnboardingPrimaryButtonColors.label)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background { buttonBackground }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let highlighted = isFocused || configuration.isPressed
        if highlighted {
            shape.fill(OnboardingPrimaryButtonColors.fill.opacity(configuration.isPressed ? 0.88 : 1))
        } else {
            shape
                .fill(Color.white.opacity(0.14))
                .overlay(shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 2))
        }
    }
}

extension View {
    /// Primary onboarding action; disables system focus chrome that can hide custom label colors.
    func onboardingPrimaryButton() -> some View {
        buttonStyle(OnboardingPrimaryButtonStyle())
            .focusEffectDisabled()
            .tint(OnboardingPrimaryButtonColors.label)
    }
}

struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
    }
}

struct OnboardingScreenLayout<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            OnboardingBackground()
            VStack(spacing: 36) {
                Spacer(minLength: 40)
                content()
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 48)
        }
    }
}
