import SwiftUI

struct ShuffleView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.peerTVShuffleTabStaleRefreshToken) private var shuffleStaleRefreshToken
    @StateObject private var vm = ShuffleViewModel()
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var didLongPress = false

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Text("Shuffle")
                        .font(.title3)
                        .bold()

                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "shuffle")
                            Text("Shuffle Again")
                        }
                        .font(.caption)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.card)
                    .disabled(vm.isLoading)
                }
                .padding(.horizontal, 50)

                LazyVGrid(columns: columns, spacing: 50) {
                    ForEach(vm.videos, id: \.stableId) { video in
                        Button {
                            if didLongPress { didLongPress = false; return }
                            PlayerPresenter.shared.play(
                                videoId: video.stableId,
                                apiClient: session.apiClient,
                                accessToken: session.tokenStore.accessToken,
                                accountId: session.activeAccountId
                            )
                        } label: {
                            VideoCardView(video: video)
                        }
                        .buttonStyle(.card)
                        .videoTilePlaylistPicker(video: video)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    didLongPress = true
                                    detailVideoId = video.stableId
                                    showDetail = true
                                }
                        )
                    }
                }
                .padding(.horizontal, 50)
            }
            .padding(.top, 40)
            .padding(.bottom, 60)

            if vm.isLoading {
                ProgressView().padding()
            }
        }
        .overlay {
            if let error = vm.errorMessage, vm.videos.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(videoId: detailVideoId)
        }
        .onAppear {
            vm.configure(apiClient: session.apiClient, instanceURL: session.baseURL)
            Task {
                if vm.videos.isEmpty {
                    await vm.loadRandom()
                }
            }
        }
        .onChange(of: shuffleStaleRefreshToken, initial: false) { _, _ in
            Task {
                vm.configure(apiClient: session.apiClient, instanceURL: session.baseURL)
                await vm.refresh()
            }
        }
        .onChange(of: session.activeAccountId, initial: false) { _, _ in
            Task {
                vm.configure(apiClient: session.apiClient, instanceURL: session.baseURL)
                await vm.refresh()
            }
        }
    }
}

private struct ShuffleTabStaleRefreshTokenKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// Incremented in `MainTabView` when returning to Shuffle after being on another tab longer than the stale threshold.
    var peerTVShuffleTabStaleRefreshToken: Int {
        get { self[ShuffleTabStaleRefreshTokenKey.self] }
        set { self[ShuffleTabStaleRefreshTokenKey.self] = newValue }
    }
}
