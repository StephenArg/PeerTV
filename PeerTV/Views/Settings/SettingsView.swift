import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @State private var shuffleEnabled = DebugFlags.shuffleTabEnabled

    var body: some View {
        List {
                Section("Instance") {
                    if let base = session.baseURL {
                        LabeledContent("URL", value: base.absoluteString)
                    }
                    if !session.username.isEmpty {
                        LabeledContent("Logged in as", value: session.username)
                    }
                }

                Section("Account") {
                    Button("Log Out") {
                        session.logout()
                    }
                    .foregroundStyle(.red)

                    Button("Change Instance") {
                        session.clearInstance()
                    }
                    .foregroundStyle(.red)
                }

                if DebugFlags.showAPIExplorer {
                    Section {
                        Toggle("Shuffle Tab", isOn: $shuffleEnabled)
                            .onChange(of: shuffleEnabled) { _, newValue in
                                DebugFlags.shuffleTabEnabled = newValue
                            }
                        NavigationLink("API Explorer") {
                            APIExplorerView()
                        }
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text("Toggling Shuffle Tab requires restarting the app.")
                    }
                }

                Section("About") {
                    LabeledContent("App Version", value: "1.0.0")
                    LabeledContent("Platform", value: "tvOS")
                }
        }
        .navigationTitle("Settings")
    }
}
