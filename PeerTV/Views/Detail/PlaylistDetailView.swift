import SwiftUI

struct PlaylistDetailView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm: PlaylistDetailViewModel
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var didLongPress = false

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    init(playlistId: Int) {
        _vm = StateObject(wrappedValue: PlaylistDetailViewModel(playlistId: playlistId))
    }

    var body: some View {
        ScrollView {
            if vm.isLoading && vm.playlist == nil {
                ProgressView()
                    .padding(.top, 200)
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    if let playlist = vm.playlist {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(playlist.displayName ?? "Playlist")
                                .font(.title2)
                                .bold()
                            if let desc = playlist.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            if let count = playlist.videosLength {
                                Text("\(count) videos")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.top, 40)
                    }

                    LazyVGrid(columns: columns, spacing: 50) {
                        ForEach(vm.elements) { element in
                            if let video = element.video {
                                Button {
                                    if didLongPress { didLongPress = false; return }
                                    PlayerPresenter.shared.play(
                                        videoId: video.stableId,
                                        apiClient: session.apiClient,
                                        accessToken: session.tokenStore.accessToken
                                    )
                                } label: {
                                    VideoCardView(video: video)
                                }
                                .buttonStyle(.card)
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.5)
                                        .onEnded { _ in
                                            didLongPress = true
                                            detailVideoId = video.stableId
                                            showDetail = true
                                        }
                                )
                                .onAppear {
                                    if element.id == vm.elements.last?.id {
                                        Task { await vm.loadMore() }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 60)
                }
            }
        }
        .overlay {
            if let error = vm.errorMessage, vm.elements.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(videoId: detailVideoId)
        }
        .task {
            vm.configure(apiClient: session.apiClient)
            await vm.loadInitial()
        }
    }
}
