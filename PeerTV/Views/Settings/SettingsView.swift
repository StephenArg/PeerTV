import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var appThemeStore: AppThemeStore
    @State private var shuffleEnabled = DebugFlags.shuffleTabEnabled
    @State private var showVideoDetailRawJSON = DebugFlags.showVideoDetailRawJSON
    @State private var showShuffleRestartAlert = false
    @State private var accountPendingSignOut: UUID?
    // Persisted via the same `UserDefaults` key read by `PlayerSettings.bufferCap` so playback
    // code and the Settings picker stay in sync across launches.
    @AppStorage(PlayerSettings.bufferCapKey) private var bufferCapRawValue: Int = BufferCap.gb1.rawValue
    @AppStorage(PlayerSettings.defaultResolutionKey) private var defaultResolutionRawValue: Int = DefaultResolution.auto.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Settings")
                    .font(.title3)
                    .bold()

                settingsSection(title: "Accounts") {
                    ForEach(session.sortedAccounts) { account in
                        accountRow(account)
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
                    Text("Select an account to use it for the whole app. Sign out removes saved login for that account only. Player, theme, and other app preferences stay shared.")
                }

                settingsSection(title: "Playback") {
                    Picker("Default quality", selection: $defaultResolutionRawValue) {
                        ForEach(DefaultResolution.allCases) { res in
                            Text(res.displayName).tag(res.rawValue)
                        }
                    }
                    Text("Default quality applies when a video opens. If the chosen resolution isn't offered, the next lower one plays (falling back to Auto if none exists). Auto uses HLS adaptive bitrate.\n")
                    Picker("Buffer cap", selection: $bufferCapRawValue) {
                        ForEach(BufferCap.allCases) { cap in
                            Text(cap.displayName).tag(cap.rawValue)
                        }
                    }
                    Text("Buffer cap is the approximate maximum AVPlayer will keep buffered ahead. Larger caps smooth over slow networks at the cost of memory.")
                }

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

                // settingsSection(title: "Appearance") {
                //     Picker("Color theme", selection: $appThemeStore.theme) {
                //         ForEach(AppColorTheme.allCases) { theme in
                //             Text(theme.displayName).tag(theme)
                //         }
                //     }
                // } footer: {
                //     Text("System follows Apple TV settings. Other themes use a dark base with a different accent color.")
                // }

                if DebugFlags.showAPIExplorer {
                    settingsSection(title: "Developer") {
                        Toggle("Shuffle Tab", isOn: $shuffleEnabled)
                            .onChange(of: shuffleEnabled) { _, newValue in
                                DebugFlags.shuffleTabEnabled = newValue
                                showShuffleRestartAlert = true
                            }

                        Toggle("Show Raw JSON on video details", isOn: $showVideoDetailRawJSON)
                            .onChange(of: showVideoDetailRawJSON) { _, newValue in
                                DebugFlags.showVideoDetailRawJSON = newValue
                            }
                    } footer: {
                        Text("Changing Shuffle Tab prompts you to quit and reopen the app so the tab bar updates.")
                    }
                }

                settingsSection(title: "About") {
                    LabeledContent("App Version", value: "1.0.0")
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
        .onAppear {
            showVideoDetailRawJSON = DebugFlags.showVideoDetailRawJSON
        }
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
        .alert("Apply shuffle tab change", isPresented: $showShuffleRestartAlert) {
            Button("Quit now") {
                exit(0)
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("PeerTV must quit and be opened again for the Shuffle tab to appear or disappear.")
        }
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
