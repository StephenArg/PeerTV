import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var appThemeStore: AppThemeStore
    @State private var shuffleEnabled = DebugFlags.shuffleTabEnabled
    @State private var showVideoDetailRawJSON = DebugFlags.showVideoDetailRawJSON
    @State private var showShuffleRestartAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Settings")
                    .font(.title3)
                    .bold()

                settingsSection(title: "Instance") {
                    if let base = session.baseURL {
                        LabeledContent("URL", value: base.absoluteString)
                    }
                    if !session.username.isEmpty {
                        LabeledContent("Logged in as", value: session.username)
                    }
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

                settingsSection(title: "Account") {
                    Button("Log Out") {
                        session.logout()
                    }
                    .foregroundStyle(.red)

                    Button("Change Instance") {
                        session.clearInstance()
                    }
                    .foregroundStyle(.red)
                }

                settingsSection(title: "Appearance") {
                    Picker("Color theme", selection: $appThemeStore.theme) {
                        ForEach(AppColorTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                } footer: {
                    Text("System follows Apple TV settings. Other themes use a dark base with a different accent color.")
                }

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
        .alert("Apply shuffle tab change", isPresented: $showShuffleRestartAlert) {
            Button("Quit now") {
                exit(0)
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("PeerTV must quit and be opened again for the Shuffle tab to appear or disappear.")
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
