import SwiftUI

/// Reference of the app's hidden / non-obvious gestures and remote controls. Surfaced from
/// Settings so users can discover interactions that aren't visually advertised in the UI.
///
/// Laid out to fit a single tvOS screen without scrolling: tiles aren't focusable, so a
/// `ScrollView` would trap content the user can never reach.
struct ControlsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Controls")
                        .font(.title3)
                        .bold()
                    Text("Gestures and remote shortcuts that aren't shown on screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.callout)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.card)
            }

            sectionHeader("Browsing")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(browsingTips) { controlRow($0) }
            }

            sectionHeader("Player")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(playerTips) { controlRow($0) }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 50)
        .padding(.top, 40)
        .padding(.bottom, 40)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func controlRow(_ tip: ControlTip) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: tip.icon)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title)
                    .font(.headline)
                Text(tip.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private let browsingTips: [ControlTip] = [
        ControlTip(
            icon: "play.rectangle.fill",
            title: "Play a video",
            detail: "Click a video tile to start playback."
        ),
        ControlTip(
            icon: "info.circle.fill",
            title: "Open video details",
            detail: "Press and hold a video tile to open its details instead of playing."
        )
    ]

    private let playerTips: [ControlTip] = [
        ControlTip(
            icon: "playpause.fill",
            title: "Play / pause",
            detail: "Tap the touchpad (select) to toggle play and pause."
        ),
        ControlTip(
            icon: "forward.fill",
            title: "Temporary fast forward",
            detail: "Touch and hold the touchpad to fast forward at 2× while held; lift to resume."
        ),
        ControlTip(
            icon: "speedometer",
            title: "Toggle 2× / 1× speed",
            detail: "Press and hold the select button to switch playback between 2× and 1×."
        ),
        ControlTip(
            icon: "slider.horizontal.below.rectangle",
            title: "Quick options",
            detail: "Double‑click the play/pause button to bring up the quick selector bar."
        ),
        ControlTip(
            icon: "forward.frame.fill",
            title: "Skim faster",
            detail: "Hold left or right on the scrubber to skim; keep holding to skim faster."
        )
    ]
}

private struct ControlTip: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}
