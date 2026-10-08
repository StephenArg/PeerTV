import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var appThemeStore: AppThemeStore
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
    @AppStorage(TabBarStyle.storageKey) private var tabBarStyle: TabBarStyle = .topBar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Settings")
                    .font(.title3)
                    .bold()

                settingsSection(title: "Accounts") {
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
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Account")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.card)
                } footer: {
                    if session.isAnonymous {
                        Text("Sign out ends anonymous browsing and returns to sign-in, or to server selection when no server is chosen. Adding an account signs you in and leaves anonymous mode.")
                    } else {
                        Text("Select an account to use it for the whole app. Sign out removes saved login for that account only. Player, theme, and other app preferences stay shared.")
                    }
                }

                if !session.isAnonymous {
                    settingsSection(title: "Downloads") {
                        NavigationLink {
                            DownloadedVideosView()
                        } label: {
                            HStack {
                                Text("Downloaded Videos")
                                Spacer()
                                Text("\(DownloadManager.shared.downloadedVideos.count) videos")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.card)
                    }
                }

                settingsSection(title: "Playback") {
                    Picker("Default quality", selection: $defaultResolutionRawValue) {
                        ForEach(DefaultResolution.allCases) { res in
                            Text(res.displayName).tag(res.rawValue)
                        }
                    }
                    Text("Default quality applies when a video opens. If the chosen resolution isn't offered, the next lower one plays (falling back to Auto if none exists). Auto uses HLS adaptive bitrate.\n")
                    Picker("Default speed", selection: $defaultPlaybackSpeed) {
                        ForEach(PlayerSettings.playbackSpeeds, id: \.self) { speed in
                            Text(PlayerSettings.speedLabel(speed)).tag(Double(speed))
                        }
                    }
                    Text("Every video starts at this speed, including the next one in a playlist. Changing speed in the player only affects the video you're watching.\n")
                    Picker("Buffer cap", selection: $bufferCapRawValue) {
                        ForEach(BufferCap.allCases) { cap in
                            Text(cap.displayName).tag(cap.rawValue)
                        }
                    }
                    Text("Buffer cap is roughly how much video is kept loaded ahead of where you are. The same cap covers less time at higher quality: far fewer minutes of 4K than of 720p. Larger caps smooth over slow networks at the cost of memory.\n")

                    Toggle("Resume playback", isOn: $resumePlaybackEnabled)
                    if resumePlaybackEnabled {
                        Button {
                            showClearPositionsAlert = true
                        } label: {
                            HStack {
                                Text("Clear saved positions")
                                Spacer()
                                Text("\(savedPositionCount) saved")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("When enabled, videos resume from where you left off. Positions are cleared when a video finishes (within 7% of the end).")

                    Toggle("Preview thumbnails on focus", isOn: $tilePreviewEnabled)
                    Text("When a video is highlighted, its tile cycles through preview frames (the same thumbnails shown when scrubbing). Turn off to always show a single static thumbnail.")

                    Toggle("Show progress on thumbnails", isOn: $showThumbnailProgressBars)
                    Text("Partially watched videos show a thin progress bar at the bottom of their thumbnail.")
                }

                settingsSection(title: "Navigation") {
                    Picker("Tab bar", selection: $tabBarStyle) {
                        ForEach(TabBarStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                } footer: {
                    Text("The sidebar needs tvOS 18 or later; earlier versions always show the top bar.")
                }

                // settingsSection(title: "Appearance") {
                //     Picker("Color theme", selection: $appThemeStore.theme) {
                //         ForEach(AppColorTheme.allCases) { theme in
                //             Text(theme.displayName).tag(theme)
                //         }
                //     }
                // } footer: {
                //     Text("System follows Apple TV settings. Other themes use a dark base with a different accent color.")
                // }

                if !session.isAnonymous, DebugFlags.showAPIExplorer {
                    settingsSection(title: "Developer") {
                        Toggle("Shuffle Tab", isOn: $shuffleEnabled)
                            .onChange(of: shuffleEnabled) { _, newValue in
                                DebugFlags.shuffleTabEnabled = newValue
                            }

                        Toggle("Show Raw JSON on video details", isOn: $showVideoDetailRawJSON)
                            .onChange(of: showVideoDetailRawJSON) { _, newValue in
                                DebugFlags.showVideoDetailRawJSON = newValue
                            }
                    } footer: {
                        Text("Shuffle needs the random-video-tab plugin on your server.")
                    }
                }

                settingsSection(title: "Help") {
                    NavigationLink {
                        ControlsHelpView()
                    } label: {
                        HStack {
                            Image(systemName: "hand.tap.fill")
                            Text("Controls")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.card)
                } footer: {
                    Text("Discover hidden gestures and remote shortcuts for browsing and playback.")
                }

                settingsSection(title: "About") {
                    LabeledContent("App Version", value: Self.appVersionText)
                    LabeledContent("Platform", value: "tvOS")
                }

                if DebugFlags.showAPIExplorer {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tools")
                            .font(.title3)
                            .bold()
                            .foregroundStyle(.secondary)

                        NavigationLink {
                            APIExplorerView()
                        } label: {
                            HStack {
                                Text("API Explorer")
                                    .font(.body)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.card)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 50)
            .padding(.top, 40)
            .padding(.bottom, 120)
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

    @ViewBuilder
    private func settingsSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        settingsSection(title: title, content: content, footer: { EmptyView() })
    }

    @ViewBuilder
    private func settingsSection<F: View>(
        title: String,
        @ViewBuilder content: () -> some View,
        @ViewBuilder footer: () -> F
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3)
                .bold()
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(.vertical, 8)

            footer()
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
