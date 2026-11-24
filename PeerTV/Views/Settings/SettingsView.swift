import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var appThemeStore: AppThemeStore
    @EnvironmentObject private var downloadManager: DownloadManager
    @State private var shuffleEnabled = DebugFlags.shuffleTabEnabled
    @State private var showVideoDetailRawJSON = DebugFlags.showVideoDetailRawJSON
    @State private var accountPendingSignOut: UUID?
    @State private var showServerSwitch = false
    /// Server picked in the switch flow, applied once its cover has closed.
    @State private var pendingAnonymousServer: URL?
    @State private var showClearPositionsAlert = false
    @State private var savedPositionCount = PlaybackPositionStore.savedPositionCount
    @State private var resumePlaybackEnabled = PlaybackPositionStore.isEnabled
    @State private var tilePreviewEnabled = TilePreviewSettings.isEnabled
    @State private var showThumbnailProgressBars = ThumbnailProgressBarSettings.isVisible
    // Persisted via the same `UserDefaults` key read by `PlayerSettings.bufferCap` so playback
    // code and the Settings picker stay in sync across launches.
    @AppStorage(PlayerSettings.bufferCapKey) private var bufferCapRawValue: Int = BufferCap.gb1.rawValue
    @AppStorage(PlayerSettings.defaultResolutionKey) private var defaultResolutionRawValue: Int = DefaultResolution.auto.rawValue
    @AppStorage(PlayerSettings.defaultPlaybackSpeedKey) private var defaultPlaybackSpeed: Double = 1.0
    @AppStorage(PlayerSettings.skipIntervalKey) private var skipInterval: Double = PlayerSettings.defaultSkipInterval
    @AppStorage(PlayerSettings.holdSpeedKey) private var holdSpeed: Double = Double(PlayerSettings.defaultHoldSpeed)
    @AppStorage(PlayerSettings.playbackStatsKey) private var playbackStatsRawValue: Int = PlaybackStatsDisplay.networkSpeed.rawValue
    @AppStorage(PlayerSettings.stillWatchingKey) private var stillWatchingRawValue: Int = StillWatchingInterval.default.rawValue
    @AppStorage(TabBarStyle.storageKey) private var tabBarStyle: TabBarStyle = .topBar

    var body: some View {
        // The outer reader keeps the safe area, so it knows how tall the tab bar region is; the
        // inner layout runs edge to edge so the brand panel fills the left half behind it.
        GeometryReader { outer in
        GeometryReader { geo in
            HStack(spacing: 0) {
                SettingsBrandPanel(versionText: Self.appVersionText, connectionText: connectionDescription)
                    .frame(width: geo.size.width / 2)

                ScrollView {
                    settingsList
                        .padding(.horizontal, 60)
                        // The layout runs under the tab bar; the list starts below it.
                        .padding(.top, 50 + outer.safeAreaInsets.top)
                        .padding(.bottom, 120)
                }
                .frame(width: geo.size.width / 2)
                .focusSection()
            }
        }
        .ignoresSafeArea()
        }
        .onAppear { refreshPlaybackSettings() }
        .onChange(of: session.phase) { _, _ in refreshPlaybackSettings() }
        .fullScreenCover(
            isPresented: Binding(
                get: { session.isAddingAccount },
                set: { session.isAddingAccount = $0 }
            ),
            onDismiss: {
                session.cancelAddAccount()
            }
        ) {
            AddAccountFlowView()
                .environmentObject(session)
        }
        .alert("Sign out this account?", isPresented: Binding(
            get: { accountPendingSignOut != nil },
            set: { if !$0 { accountPendingSignOut = nil } }
        )) {
            Button("Sign Out", role: .destructive) {
                if let id = accountPendingSignOut {
                    session.signOut(accountId: id)
                }
                accountPendingSignOut = nil
            }
            Button("Cancel", role: .cancel) {
                accountPendingSignOut = nil
            }
        } message: {
            Text("You will stay signed in on your other accounts.")
        }
        .alert("Clear all saved positions?", isPresented: $showClearPositionsAlert) {
            Button("Clear All", role: .destructive) {
                if session.isAnonymous {
                    PlaybackPositionStore.clearAnonymousPositions()
                } else {
                    PlaybackPositionStore.clearAll()
                }
                refreshPlaybackSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \(savedPositionCount) saved playback positions. Videos will start from the beginning.")
        }
        .onChange(of: resumePlaybackEnabled) { _, newValue in
            PlaybackPositionStore.isEnabled = newValue
        }
        .onChange(of: tilePreviewEnabled) { _, newValue in
            TilePreviewSettings.isEnabled = newValue
        }
        .onChange(of: showThumbnailProgressBars) { _, newValue in
            ThumbnailProgressBarSettings.isVisible = newValue
        }
    }

    /// What the brand panel says the app is connected to.
    private var connectionDescription: String {
        if session.isAnonymous {
            if let host = session.baseURL?.host, !host.isEmpty { return "Browsing \(host) anonymously" }
            return "Browsing anonymously"
        }
        if let account = session.sortedAccounts.first(where: { $0.id == session.activeAccountId }) {
            return "Signed in as \(account.handle)"
        }
        return session.baseURL?.host ?? ""
    }

    // MARK: - Settings list (right half)

    @ViewBuilder
    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 44) {
            Text("Settings")
                .font(.title2)
                .bold()

            SettingsListSection(
                title: "Accounts",
                footer: session.isAnonymous
                    ? "Sign out ends anonymous browsing. Adding an account signs you in and leaves anonymous mode."
                    : "The selected account is used across the app. Sign out removes that account's saved login only."
            ) {
                if session.isAnonymous {
                    anonymousAccountsSection
                } else {
                    ForEach(session.sortedAccounts) { account in
                        accountRow(account)
                    }
                }
                Button {
                    session.beginAddAccount()
                } label: {
                    SettingsRowLabel(title: "Add Account", systemImage: "plus.circle.fill", showsChevron: true)
                }
                .buttonStyle(.card)
            }

            if !session.isAnonymous {
                SettingsListSection(title: "Downloads") {
                    NavigationLink {
                        DownloadedVideosView()
                    } label: {
                        SettingsRowLabel(
                            title: "Downloaded Videos",
                            systemImage: "arrow.down.circle",
                            value: downloadManager.downloadedVideos.isEmpty ? "None" : downloadManager.downloadedVideos.storageSummary,
                            showsChevron: true
                        )
                    }
                    .buttonStyle(.card)
                }
            }

            SettingsListSection(title: "Playback") {
                SettingsChoiceRow(
                    title: "Default quality",
                    message: "Applies when a video opens. If that resolution isn't offered, the next lower one plays, or Auto if none is. Auto uses HLS adaptive bitrate.",
                    options: DefaultResolution.allCases.map { ($0.rawValue, $0.displayName) },
                    selection: $defaultResolutionRawValue
                )
                SettingsChoiceRow(
                    title: "Default speed",
                    message: "Every video starts at this speed, including the next one in a playlist. Changing speed in the player only affects the video you're watching.",
                    options: PlayerSettings.playbackSpeeds.map { (Double($0), PlayerSettings.speedLabel($0)) },
                    selection: $defaultPlaybackSpeed
                )
                SettingsChoiceRow(
                    title: "Hold speed",
                    message: "Speed while you hold the touchpad click, or rest a finger on the touchpad during playback.",
                    options: PlayerSettings.holdSpeeds.map { (Double($0), PlayerSettings.speedLabel($0)) },
                    selection: $holdSpeed
                )
                SettingsChoiceRow(
                    title: "Skip interval",
                    message: "How far a left or right tap on the scrubber jumps.",
                    options: PlayerSettings.skipIntervals.map { ($0, "\(Int($0)) seconds") },
                    selection: $skipInterval
                )
                SettingsChoiceRow(
                    title: "Playback stats",
                    message: "The readout under the scrubber: download speed and buffering, optionally with the playing resolution and bitrate, or nothing.",
                    options: PlaybackStatsDisplay.allCases.map { ($0.rawValue, $0.displayName) },
                    selection: $playbackStatsRawValue
                )
                SettingsChoiceRow(
                    title: "Still watching?",
                    message: "Playlists only. When a video ends and the next one is about to start, the player asks whether you’re still watching if the remote hasn’t been used for this long. Any press on the remote restarts the count.",
                    options: StillWatchingInterval.allCases.map { ($0.rawValue, $0.displayName) },
                    selection: $stillWatchingRawValue
                )
                SettingsChoiceRow(
                    title: "Buffer cap",
                    message: "Roughly how much video is kept loaded ahead of where you are. The same cap covers less time at higher quality. Larger caps smooth over slow networks at the cost of memory.",
                    options: BufferCap.allCases.map { ($0.rawValue, $0.displayName) },
                    selection: $bufferCapRawValue
                )
                SettingsToggleRow(
                    title: "Resume playback",
                    subtitle: "Pick up where you left off. Cleared when a video finishes.",
                    isOn: $resumePlaybackEnabled
                )
                if resumePlaybackEnabled {
                    Button {
                        showClearPositionsAlert = true
                    } label: {
                        SettingsRowLabel(title: "Clear saved positions", value: "\(savedPositionCount) saved")
                    }
                    .buttonStyle(.card)
                }
                SettingsToggleRow(
                    title: "Preview thumbnails on focus",
                    subtitle: "Highlighted tiles cycle through preview frames.",
                    isOn: $tilePreviewEnabled
                )
                SettingsToggleRow(
                    title: "Show progress on thumbnails",
                    subtitle: "A thin bar on partly watched videos.",
                    isOn: $showThumbnailProgressBars
                )
            }

            SettingsListSection(
                title: "Restrictions",
                footer: "For shared TVs. With a PIN set, PeerTV asks for it when it opens and when you come back after being away longer than “Ask for PIN” allows, and to unblock a channel, show sensitive videos or turn the lock off. Blocking never needs it. The PIN is stored only in the app: deleting PeerTV removes it, which is also the way out of a forgotten PIN."
            ) {
                RestrictionsSettingsView()
            }

            SettingsListSection(title: "Navigation", footer: "The sidebar needs tvOS 18 or later; earlier versions always show the top bar.") {
                SettingsChoiceRow(
                    title: "Tab bar",
                    options: TabBarStyle.allCases.map { ($0, $0.displayName) },
                    selection: $tabBarStyle
                )
            }

            if !session.isAnonymous, DebugFlags.showAPIExplorer {
                SettingsListSection(title: "Developer", footer: "Shuffle needs the random-video-tab plugin on your server.") {
                    SettingsToggleRow(title: "Shuffle Tab", isOn: shuffleEnabled) { newValue in
                        shuffleEnabled = newValue
                        DebugFlags.shuffleTabEnabled = newValue
                    }
                    SettingsToggleRow(title: "Show Raw JSON on video details", isOn: showVideoDetailRawJSON) { newValue in
                        showVideoDetailRawJSON = newValue
                        DebugFlags.showVideoDetailRawJSON = newValue
                    }
                    NavigationLink {
                        APIExplorerView()
                    } label: {
                        SettingsRowLabel(title: "API Explorer", systemImage: "curlybraces", showsChevron: true)
                    }
                    .buttonStyle(.card)
                }
            }

            SettingsListSection(title: "Help") {
                NavigationLink {
                    ControlsHelpView()
                } label: {
                    SettingsRowLabel(
                        title: "Controls",
                        systemImage: "hand.tap.fill",
                        subtitle: "Gestures and remote shortcuts for browsing and playback.",
                        showsChevron: true
                    )
                }
                .buttonStyle(.card)
            }

            SettingsListSection(title: "About") {
                SettingsInfoRow(title: "App Version", value: Self.appVersionText)
                SettingsInfoRow(title: "Platform", value: "tvOS")
            }
        }
    }

    /// Marketing version and build number from the bundle, e.g. "1.16 (16)".
    private static let appVersionText: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }()

    private func refreshPlaybackSettings() {
        showVideoDetailRawJSON = DebugFlags.showVideoDetailRawJSON
        resumePlaybackEnabled = PlaybackPositionStore.isEnabled
        tilePreviewEnabled = TilePreviewSettings.isEnabled
        showThumbnailProgressBars = ThumbnailProgressBarSettings.isVisible
        if session.isAnonymous {
            savedPositionCount = PlaybackPositionStore.savedPositionCount(
                for: PlaybackPositionStore.anonymousAccountId
            )
        } else {
            savedPositionCount = PlaybackPositionStore.savedPositionCount
        }
    }

    private var anonymousScopeDescription: String {
        if let host = session.baseURL?.host, !host.isEmpty {
            return "Public videos on \(host)"
        }
        return "Fediverse trending and Sepia Search only"
    }

    private var anonymousAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Browsing anonymously")
                        .font(.headline)
                    Text(anonymousScopeDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)

                Button {
                    showServerSwitch = true
                } label: {
                    Text(session.baseURL == nil ? "Choose Server" : "Switch Server")
                        .foregroundStyle(.white)
                }

                Button {
                    session.leaveAnonymousMode()
                } label: {
                    Text("Sign Out")
                        .foregroundStyle(.white)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            )
        }
        .fullScreenCover(isPresented: $showServerSwitch, onDismiss: applyPendingAnonymousServer) {
            ServerSwitchFlowView { url in
                pendingAnonymousServer = url
            }
        }
    }

    /// Switching rebuilds the tabs for the new server, so it waits until the cover is gone.
    private func applyPendingAnonymousServer() {
        guard let url = pendingAnonymousServer else { return }
        pendingAnonymousServer = nil
        session.switchAnonymousServer(to: url)
    }

    private func accountRow(_ account: AccountRecord) -> some View {
        let isActive = session.activeAccountId == account.id
        let avatarURL = PeerTubeAssetURL.resolve(path: account.avatarPath, instanceBase: account.baseURL, federatedHost: nil)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                Group {
                    if let avatarURL {
                        AsyncImage(url: avatarURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            default:
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(account.title)
                            .font(.headline)
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Active account")
                        }
                    }
                    Text(account.handle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(account.baseURL.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)

                if !isActive {
                    Button("Use") {
                        session.switchAccount(account.id)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    accountPendingSignOut = account.id
                } label: {
                    Text("Sign Out")
                        .foregroundStyle(.white)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isActive ? 2 : 1)
            )
        }
    }
}
