import SwiftUI

// MARK: - Brand panel (left half)

/// Left half of Settings: the app icon (the `PeerTVLogo` image, the icon's front layer) over a
/// slow, layered backdrop in the icon's colours (glowing orbs, rings and a rotating sweep), with
/// the version and what the app is connected to.
struct SettingsBrandPanel: View {
    let versionText: String
    let connectionText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false
    @State private var breathe = false

    // Taken from the icon: the glowing orange play button, its amber sparks, and chrome.
    private static let orange = Color(red: 1.00, green: 0.45, blue: 0.08)
    private static let amber = Color(red: 1.00, green: 0.70, blue: 0.25)
    private static let ember = Color(red: 0.75, green: 0.18, blue: 0.05)

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 26) {
                ZStack {
                    // Concentric rings around the mark.
                    ForEach(0..<4, id: \.self) { ring in
                        Circle()
                            .strokeBorder(Color.white.opacity(0.16 - Double(ring) * 0.03), lineWidth: 1.5)
                            .frame(width: 300 + CGFloat(ring) * 110, height: 300 + CGFloat(ring) * 110)
                    }

                    // A comet-like sweep travelling around the inner ring.
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(
                            AngularGradient(
                                colors: [Self.orange.opacity(0), Self.orange, Self.amber],
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(108)
                            ),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: 410, height: 410)
                        .shadow(color: Self.orange.opacity(0.9), radius: 12)
                        .rotationEffect(.degrees(spin ? 360 : 0))

                    // The icon's own drop shadow (a hard black oval under the feet, rows ~700–746 of
                    // 768) reads as a blob on this dark backdrop. It is faded out below the feet and
                    // replaced with a soft glow, as if the screen's light spilled onto the floor.
                    Ellipse()
                        .fill(RadialGradient(
                            colors: [Self.orange.opacity(breathe ? 0.55 : 0.38), Self.ember.opacity(0.15), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 150
                        ))
                        .frame(width: 300, height: 44)
                        .blur(radius: 12)
                        .offset(y: 142)

                    Image("PeerTVLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 520)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.895),
                                    .init(color: .clear, location: 0.915)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: Self.orange.opacity(breathe ? 0.55 : 0.3), radius: breathe ? 50 : 30)
                        .accessibilityHidden(true)
                }
                .frame(height: 560)

                Text("PeerTV")
                    .font(.system(size: 76, weight: .heavy, design: .rounded))

                Text("PeerTube on Apple TV")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text(connectionText)
                        .lineLimit(1)
                    Text("Version \(versionText)")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
            }
            .padding(.horizontal, 40)
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.07, blue: 0.08), Color(red: 0.13, green: 0.11, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Self.orange.opacity(0.32))
                .frame(width: 620)
                .blur(radius: 160)
                .offset(x: -220, y: breathe ? -280 : -240)
            Circle()
                .fill(Self.ember.opacity(0.40))
                .frame(width: 560)
                .blur(radius: 170)
                .offset(x: 260, y: breathe ? 300 : 340)
            Circle()
                .fill(Self.amber.opacity(0.16))
                .frame(width: 420)
                .blur(radius: 140)
                .offset(x: 240, y: -300)
            // Softens the edge against the settings list on the right.
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .trailing)
        }
        // Runs up behind the tab bar; clipped after growing so the glow stays in the left half.
        .ignoresSafeArea()
        .clipped()
    }
}

// MARK: - Rows (right half)

/// Shared look for every settings row: title (and an optional one-line note) on the left,
/// the current value and an optional chevron on the right.
struct SettingsRowLabel: View {
    let title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    var value: String? = nil
    var showsChevron = false

    var body: some View {
        HStack(spacing: 18) {
            if let systemImage {
                Image(systemName: systemImage)
                    .frame(width: 36)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 20)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.vertical, 18)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A setting with several options: shows the current one and a chevron, and opens a menu of
/// all of them. `onSelect` decides what choosing does (some ask for the PIN first).
struct SettingsChoiceRow<Value: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    /// Shown above the options in the menu, to explain the setting.
    var message: String? = nil
    let options: [(value: Value, label: String)]
    let selection: Value
    let onSelect: (Value) -> Void

    @State private var showsMenu = false

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Button {
            showsMenu = true
        } label: {
            SettingsRowLabel(title: title, subtitle: subtitle, value: currentLabel, showsChevron: true)
        }
        .buttonStyle(.card)
        .confirmationDialog(title, isPresented: $showsMenu, titleVisibility: .visible) {
            ForEach(options, id: \.value) { option in
                Button(option.value == selection ? "\(option.label) ✓" : option.label) {
                    onSelect(option.value)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let message {
                Text(message)
            }
        }
    }
}

extension SettingsChoiceRow {
    /// For a plain binding with no side effects.
    init(
        title: String,
        subtitle: String? = nil,
        message: String? = nil,
        options: [(value: Value, label: String)],
        selection: Binding<Value>
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            message: message,
            options: options,
            selection: selection.wrappedValue,
            onSelect: { selection.wrappedValue = $0 }
        )
    }
}

/// An on/off setting: one press flips it. `onChange` decides what flipping does (some ask for
/// the PIN first).
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!isOn)
        } label: {
            SettingsRowLabel(title: title, subtitle: subtitle, value: isOn ? "On" : "Off")
        }
        .buttonStyle(.card)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

extension SettingsToggleRow {
    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(title: title, subtitle: subtitle, isOn: isOn.wrappedValue) { isOn.wrappedValue = $0 }
    }
}

/// Read-only line (About).
struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        SettingsRowLabel(title: title, value: value)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
    }
}

/// Section title and an optional footer in the settings list.
struct SettingsListSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}
