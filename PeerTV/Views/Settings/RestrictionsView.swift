import SwiftUI

// MARK: - PIN entry

/// What a PIN sheet is for. `set` asks for the new PIN twice.
enum PINPrompt: Identifiable {
    case unlock(reason: String, onSuccess: (String) -> Void)
    case set(onSuccess: (String) -> Void)
    case change

    var id: String {
        switch self {
        case .unlock: return "unlock"
        case .set: return "set"
        case .change: return "change"
        }
    }
}

/// Four-digit PIN entry for the parental lock. Uses the tvOS keyboard's number pad.
struct PINEntryView: View {
    let prompt: PINPrompt

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var restrictions = ContentRestrictions.shared
    @State private var entry = ""
    @State private var firstEntry: String?
    @State private var currentPIN: String?
    @State private var message: String?

    private var title: String {
        switch prompt {
        case .unlock: return "Enter PIN"
        case .set: return firstEntry == nil ? "Choose a PIN" : "Confirm PIN"
        case .change:
            if currentPIN == nil { return "Enter Current PIN" }
            return firstEntry == nil ? "Choose a New PIN" : "Confirm New PIN"
        }
    }

    private var subtitle: String {
        switch prompt {
        case .unlock(let reason, _): return reason
        case .set: return firstEntry == nil ? "Four digits. You'll need it to change these settings or turn them off." : "Enter the same four digits again."
        case .change: return currentPIN == nil ? "The PIN that is set now." : (firstEntry == nil ? "Four digits." : "Enter the same four digits again.")
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "lock.fill")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .bold()
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)

            PINDigitPad(entry: $entry, onComplete: submit)
                .onChange(of: entry) { _, value in
                    if !value.isEmpty { message = nil }
                }

            Text(message ?? " ")
                .font(.callout)
                .foregroundStyle(.red)

            Button("Cancel", role: .cancel) { dismiss() }
        }
        .padding(60)
    }

    private func submit() {
        guard ContentRestrictions.isValidPIN(entry) else {
            message = "Enter four digits."
            return
        }
        let pin = entry
        switch prompt {
        case .unlock(_, let onSuccess):
            guard restrictions.verify(pin) else {
                message = "Wrong PIN."
                entry = ""
                return
            }
            dismiss()
            onSuccess(pin)
        case .set(let onSuccess):
            if let first = firstEntry {
                guard first == pin else {
                    message = "The PINs didn't match. Start again."
                    firstEntry = nil
                    entry = ""
                    return
                }
                dismiss()
                onSuccess(pin)
            } else {
                firstEntry = pin
                entry = ""
            }
        case .change:
            if currentPIN == nil {
                guard restrictions.verify(pin) else {
                    message = "Wrong PIN."
                    entry = ""
                    return
                }
                currentPIN = pin
                entry = ""
            } else if let first = firstEntry {
                guard first == pin else {
                    message = "The PINs didn't match. Start again."
                    firstEntry = nil
                    entry = ""
                    return
                }
                restrictions.setPIN(pin, currentPIN: currentPIN)
                dismiss()
            } else {
                firstEntry = pin
                entry = ""
            }
        }
    }
}

// MARK: - Digit pad

/// PIN entry without the system keyboard: four dots and a row of 0–9 buttons, like the Apple TV's
/// own Restrictions passcode. (The tvOS keyboard ignores the number-pad request the first time a
/// secure field opens and shows letters.) Calls `onComplete` once four digits are in.
struct PINDigitPad: View {
    @Binding var entry: String
    var isDisabled = false
    let onComplete: () -> Void

    @FocusState private var focusedKey: String?

    private static let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    var body: some View {
        VStack(spacing: 40) {
            HStack(spacing: 28) {
                ForEach(0..<ContentRestrictions.pinLength, id: \.self) { index in
                    Circle()
                        .strokeBorder(Color.white.opacity(0.6), lineWidth: 3)
                        .background(Circle().fill(index < entry.count ? Color.white : Color.clear))
                        .frame(width: 34, height: 34)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.count) of \(ContentRestrictions.pinLength) digits entered")

            HStack(spacing: 18) {
                ForEach(Self.digits, id: \.self) { digit in
                    Button {
                        append(digit)
                    } label: {
                        Text(digit)
                            .font(.title2)
                            .monospacedDigit()
                            .frame(width: 84, height: 84)
                    }
                    .buttonStyle(.card)
                    .focused($focusedKey, equals: digit)
                }

                Button {
                    if !entry.isEmpty { entry.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title3)
                        .frame(width: 84, height: 84)
                }
                .buttonStyle(.card)
                .focused($focusedKey, equals: "delete")
                .accessibilityLabel("Delete")
            }
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.4 : 1)
            .focusSection()
        }
        .defaultFocus($focusedKey, "1")
        .onAppear { focusedKey = "1" }
    }

    private func append(_ digit: String) {
        guard !isDisabled, entry.count < ContentRestrictions.pinLength else { return }
        entry.append(digit)
        if entry.count == ContentRestrictions.pinLength {
            // Let the fourth dot fill before checking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onComplete)
        }
    }
}

// MARK: - Block button

/// Block / Unblock for one channel. Blocking is one press; unblocking asks for the PIN while
/// the lock is on.
struct ChannelBlockButton: View {
    let handle: String
    let displayName: String

    @ObservedObject private var restrictions = ContentRestrictions.shared
    @State private var pinPrompt: PINPrompt?

    private var isBlocked: Bool { restrictions.isBlocked(handle: handle) }

    var body: some View {
        Button {
            if isBlocked {
                if restrictions.isLocked {
                    pinPrompt = .unlock(reason: "Unblocking \(displayName) needs the PIN.") { pin in
                        restrictions.unblock(handle: handle, pin: pin)
                    }
                } else {
                    restrictions.unblock(handle: handle, pin: nil)
                }
            } else {
                restrictions.block(handle: handle, displayName: displayName)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isBlocked ? "hand.raised.slash" : "hand.raised")
                Text(isBlocked ? "Unblock" : "Block")
            }
            .font(.callout)
            .fontWeight(.semibold)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .buttonStyle(.card)
        .accessibilityHint(isBlocked ? "Shows this channel's videos again" : "Hides this channel everywhere in the app")
        .sheet(item: $pinPrompt) { prompt in
            PINEntryView(prompt: prompt)
        }
    }
}

// MARK: - Settings section content

/// Settings → Restrictions: the lock, sensitive videos and the block list.
struct RestrictionsSettingsView: View {
    @ObservedObject private var restrictions = ContentRestrictions.shared
    @State private var pinPrompt: PINPrompt?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if restrictions.isLocked {
                    pinPrompt = .unlock(reason: "Turning the lock off needs the PIN.") { pin in
                        restrictions.removePIN(pin: pin)
                    }
                } else {
                    pinPrompt = .set { pin in
                        restrictions.setPIN(pin)
                    }
                }
            } label: {
                SettingsRowLabel(
                    title: "PIN Lock",
                    systemImage: restrictions.isLocked ? "lock.fill" : "lock.open",
                    subtitle: restrictions.isLocked ? "Press to turn off." : "Press to choose a PIN.",
                    value: restrictions.isLocked ? "On" : "Off"
                )
            }
            .buttonStyle(.card)

            if restrictions.isLocked {
                Button {
                    pinPrompt = .change
                } label: {
                    SettingsRowLabel(title: "Change PIN", systemImage: "key", showsChevron: true)
                }
                .buttonStyle(.card)

                SettingsChoiceRow(
                    title: "Ask for PIN",
                    message: "How long PeerTV can be left before coming back to it asks for the PIN. Opening the app fresh always asks.",
                    options: AppLockDelay.allCases.map { ($0, $0.displayName) },
                    selection: restrictions.lockDelay
                ) { delay in
                    guard delay != restrictions.lockDelay else { return }
                    pinPrompt = .unlock(reason: "Changing when PeerTV locks needs the PIN.") { pin in
                        restrictions.setLockDelay(delay, pin: pin)
                    }
                }
            }

            SettingsToggleRow(
                title: "Hide sensitive videos",
                subtitle: "Videos their uploader marked sensitive.",
                isOn: restrictions.hideSensitive
            ) { hide in
                if restrictions.isLocked {
                    pinPrompt = .unlock(reason: "Changing this needs the PIN.") { pin in
                        restrictions.setHideSensitive(hide, pin: pin)
                    }
                } else {
                    restrictions.setHideSensitive(hide, pin: nil)
                }
            }

            NavigationLink {
                BlockedChannelsListView()
            } label: {
                SettingsRowLabel(
                    title: "Blocked Channels",
                    systemImage: "hand.raised",
                    value: restrictions.blockedChannels.isEmpty ? "None" : "\(restrictions.blockedChannels.count)",
                    showsChevron: true
                )
            }
            .buttonStyle(.card)
        }
        .sheet(item: $pinPrompt) { prompt in
            PINEntryView(prompt: prompt)
        }
    }
}

/// Settings → Restrictions → Blocked Channels.
struct BlockedChannelsListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var restrictions = ContentRestrictions.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(spacing: 6) {
                    Text("Blocked Channels")
                        .font(.title3)
                        .bold()
                    Text("Videos from these channels are hidden everywhere in the app, on every account and server. Block a channel from its page or from a video's page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1100)
                }
                .frame(maxWidth: .infinity)

                if restrictions.blockedChannels.isEmpty {
                    // Something focusable: with nothing to focus, tvOS has nowhere to send the Back press.
                    VStack(spacing: 28) {
                        ContentUnavailableView(
                            "No Blocked Channels",
                            systemImage: "hand.raised",
                            description: Text("Open a channel and press Block to hide it.")
                        )
                        Button {
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "chevron.backward")
                                Text("Back")
                            }
                            .font(.callout)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(restrictions.blockedChannels.sorted { $0.blockedAt > $1.blockedAt }) { channel in
                            HStack(spacing: 20) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(channel.displayName)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(channel.handle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                ChannelBlockButton(handle: channel.handle, displayName: channel.displayName)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 50)
            .padding(.top, 40)
            .padding(.bottom, 120)
        }
    }
}

// MARK: - App lock

/// While a PIN is set, PeerTV opens to a PIN screen at launch, and again when it comes back after
/// being away (on the Apple TV Home screen or in another app) for at least the Lock setting's
/// delay. Nothing inside the app (closing the player, switching tabs) locks it. The screen lives
/// in its own window above the app's, so it also covers the player and anything else on screen.
///
/// The PIN is kept in the app's UserDefaults, never the Keychain, so deleting PeerTV removes it.
@MainActor
final class AppLockController {
    static let shared = AppLockController()

    private var lockWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var didCheckLaunch = false
    private var backgroundedAt: Date?

    var isShowing: Bool { lockWindow != nil }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLockController.shared.didEnterBackground() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLockController.shared.willEnterForeground() }
        }
    }

    /// Locks once per launch; later calls (the root view reappearing) do nothing.
    func lockAtLaunchIfNeeded() {
        guard !didCheckLaunch else { return }
        didCheckLaunch = true
        lockIfNeeded()
    }

    private func didEnterBackground() {
        backgroundedAt = Date()
        // With no grace period, cover the app now so it never shows unlocked on return.
        if ContentRestrictions.shared.lockDelay == .immediately {
            lockIfNeeded()
        }
    }

    private func willEnterForeground() {
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        if Date().timeIntervalSince(since) >= ContentRestrictions.shared.lockDelay.seconds {
            lockIfNeeded()
        }
    }

    private func lockIfNeeded() {
        guard ContentRestrictions.shared.isLocked, lockWindow == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }

        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AppLockView { [weak self] in self?.unlock() })
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        lockWindow = window
    }

    private func unlock() {
        lockWindow?.isHidden = true
        lockWindow = nil
        previousKeyWindow?.makeKeyAndVisible()
        previousKeyWindow = nil
    }
}

/// Full-screen PIN prompt shown by `AppLockController`. There is no way past it but the PIN.
struct AppLockView: View {
    let onUnlock: () -> Void

    @ObservedObject private var restrictions = ContentRestrictions.shared
    @State private var entry = ""
    @State private var message: String?
    @State private var failedAttempts = 0
    @State private var lockedOutUntil: Date?

    /// After this many wrong PINs in a row, entry pauses for `lockoutSeconds`.
    private static let attemptsBeforeLockout = 5
    private static let lockoutSeconds: TimeInterval = 30

    private var isLockedOut: Bool {
        lockedOutUntil.map { $0 > Date() } ?? false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("PeerTV is Locked")
                    .font(.title2)
                    .bold()
                Text("Enter the PIN to continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                PINDigitPad(entry: $entry, isDisabled: isLockedOut, onComplete: submit)
                    .onChange(of: entry) { _, value in
                        if !value.isEmpty, !isLockedOut { message = nil }
                    }

                Text(message ?? " ")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)

                Text("Forgot the PIN? Delete PeerTV from this Apple TV and install it again. That removes the PIN along with the app's settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                    .padding(.top, 40)
            }
            .padding(60)
        }
    }

    private func submit() {
        guard !isLockedOut, ContentRestrictions.isValidPIN(entry) else { return }
        if restrictions.verify(entry) {
            failedAttempts = 0
            entry = ""
            onUnlock()
            return
        }
        failedAttempts += 1
        entry = ""
        if failedAttempts >= Self.attemptsBeforeLockout {
            failedAttempts = 0
            let until = Date().addingTimeInterval(Self.lockoutSeconds)
            lockedOutUntil = until
            message = "Too many wrong PINs. Try again in \(Int(Self.lockoutSeconds)) seconds."
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.lockoutSeconds * 1_000_000_000))
                if lockedOutUntil == until {
                    lockedOutUntil = nil
                    message = nil
                }
            }
        } else {
            message = "Wrong PIN."
        }
    }
}
