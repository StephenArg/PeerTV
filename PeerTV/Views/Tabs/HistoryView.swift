import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = HistoryViewModel()
    @StateObject private var anonymousVM = AnonymousHistoryViewModel()
    @State private var detailVideoId: String = ""
    @State private var detailOriginHost: String?
    @State private var detailCommentReadHost: String?
    @State private var showDetail = false
    @State private var didLongPress = false
    /// False when another tab is selected so we do not scroll/focus this grid when the player dismisses from elsewhere.
    @State private var isHistoryGridOnScreen = false
    @FocusState private var historyGridFocusVideoId: String?

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    private func historyCellScrollId(videoId: String) -> String {
        "historyCell-\(videoId)"
    }

    private var displayVideos: [Video] {
        session.isAnonymous ? anonymousVM.videos : vm.videos
    }

    private var isLoading: Bool {
        session.isAnonymous ? false : vm.isLoading
    }

    private var errorMessage: String? {
        session.isAnonymous ? nil : vm.errorMessage
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text("History")
                        .font(.title3)
                        .bold()
                        .padding(.horizontal, 50)

                    LazyVGrid(columns: columns, spacing: 50) {
                        ForEach(displayVideos, id: \.stableId) { video in
                            Button {
                                if didLongPress { didLongPress = false; return }
                                playVideo(video)
                            } label: {
                                VideoCardView(
                                    video: video,
                                    showOriginHost: session.isAnonymous,
                                    thumbnailURLOverride: session.isAnonymous
                                        ? anonymousVM.thumbnailURLByVideoId[video.stableId]
                                        : nil,
                                    avatarURLOverride: session.isAnonymous
                                        ? anonymousVM.avatarURLByVideoId[video.stableId]
                                        : nil
                                )
                            }
                            .buttonStyle(.card)
                            .videoTilePlaylistPicker(video: video, showOriginHost: session.isAnonymous)
                            .focused($historyGridFocusVideoId, equals: video.stableId)
                            .id(historyCellScrollId(videoId: video.stableId))
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .onEnded { _ in
                                        didLongPress = true
                                        detailVideoId = video.stableId
                                        if session.isAnonymous {
                                            detailOriginHost = anonymousVM.originHostByVideoId[video.stableId]
                                            detailCommentReadHost = anonymousVM.commentReadHostByVideoId[video.stableId]
                                        } else {
                                            detailOriginHost = nil
                                            detailCommentReadHost = nil
                                        }
                                        showDetail = true
                                    }
                            )
                            .onAppear {
                                if !session.isAnonymous, video.stableId == vm.videos.last?.stableId {
                                    Task { await vm.loadMore() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 50)
                }
                .padding(.top, 40)
                .padding(.bottom, 60)

                if isLoading {
                    ProgressView().padding()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .peerTVPlayerDismissed)) { note in
                guard isHistoryGridOnScreen else { return }
                guard let id = note.userInfo?["videoId"] as? String else { return }
                guard displayVideos.contains(where: { $0.stableId == id }) else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    historyGridFocusVideoId = id
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(historyCellScrollId(videoId: id), anchor: .center)
                    }
                }
            }
        }
        .overlay {
            if let error = errorMessage, displayVideos.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
            if !isLoading && displayVideos.isEmpty && errorMessage == nil {
                ContentUnavailableView(
                    "No watch history",
                    systemImage: "clock",
                    description: Text(session.isAnonymous
                        ? "Videos you play during this anonymous session appear here."
                        : "Videos you watch will appear here.")
                )
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(
                videoId: detailVideoId,
                originHost: detailOriginHost,
                commentReadHost: detailCommentReadHost
            )
        }
        .onAppear { isHistoryGridOnScreen = true }
        .onDisappear { isHistoryGridOnScreen = false }
        .task {
            if session.isAnonymous {
                anonymousVM.bind()
            } else {
                vm.configure(apiClient: session.apiClient)
                await vm.loadInitialIfEmpty()
            }
        }
        .onChange(of: session.isAnonymous) { _, anonymous in
            if anonymous {
                anonymousVM.bind()
            } else {
                vm.configure(apiClient: session.apiClient)
                Task { await vm.loadInitial() }
            }
        }
    }

    private func playVideo(_ video: Video) {
        if session.isAnonymous {
            let hosts = video.federatedAPIHosts
            if let firstHost = anonymousVM.originHostByVideoId[video.stableId] ?? hosts.first {
                let apiHosts = hosts.isEmpty ? [firstHost] : hosts
                let tileThumb = VideoTileImageURL.thumbnail(
                    for: video,
                    session: session,
                    federatedDisplay: true,
                    override: anonymousVM.thumbnailURLByVideoId[video.stableId]
                )
                let tileAvatar = VideoTileImageURL.channelAvatar(
                    for: video,
                    session: session,
                    federatedDisplay: true,
                    override: anonymousVM.avatarURLByVideoId[video.stableId]
                )
                PlayerPresenter.shared.play(
                    videoId: video.stableId,
                    apiClient: PeerTubeOriginClients.publicClient(forHost: firstHost),
                    accessToken: nil,
                    apiHosts: apiHosts,
                    accountId: session.playbackAccountId,
                    historyTileThumbnailURL: tileThumb,
                    historyTileChannelAvatarURL: tileAvatar
                )
            }
            return
        }
        PlayerPresenter.shared.play(
            videoId: video.stableId,
            apiClient: session.apiClient,
            accessToken: session.tokenStore.accessToken,
            accountId: session.playbackAccountId
        )
    }
}
