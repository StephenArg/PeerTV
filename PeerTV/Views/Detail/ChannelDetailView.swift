import SwiftUI

struct ChannelDetailView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm: ChannelDetailViewModel
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var didLongPress = false
    /// False while another screen covers this one (e.g. UIKit player) so we can defer focus restore to `onAppear`.
    @State private var isChannelGridOnScreen = false
    @State private var pendingFocusVideoId: String?
    @FocusState private var channelGridFocusVideoId: String?

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    init(handle: String) {
        _vm = StateObject(wrappedValue: ChannelDetailViewModel(handle: handle))
    }

    private func channelCellScrollId(videoId: String) -> String {
        "channelCell-\(vm.handle)-\(videoId)"
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                if vm.isLoading && vm.channel == nil {
                    ProgressView()
                        .padding(.top, 200)
                } else if let channel = vm.channel {
                    VStack(alignment: .leading, spacing: 30) {
                        // Header
                        HStack(spacing: 24) {
                            ChannelAvatarView(
                                url: session.thumbnailURL(
                                    path: channel.avatars?.last?.path
                                          ?? channel.ownerAccount?.avatars?.last?.path
                                )
                            )
                            .frame(width: 120, height: 120)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(channel.displayName ?? channel.name ?? "")
                                    .font(.title2)
                                    .bold()
                                if let desc = channel.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                                if let followers = channel.followersCount {
                                    Text("\(followers) followers")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            if session.phase == .authenticated && !vm.isOwnChannel {
                                Button {
                                    Task { await vm.toggleSubscription() }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: vm.isSubscribed ? "checkmark.circle.fill" : "plus.circle")
                                        Text(vm.isSubscribed ? "Subscribed" : "Subscribe")
                                    }
                                    .font(.callout)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 14)
                                }
                                .buttonStyle(.card)
                                .disabled(vm.isTogglingSubscription)
                                .opacity(vm.isTogglingSubscription ? 0.6 : 1.0)
                            }
                        }
                        .padding(.horizontal, 50)
                        .padding(.top, 40)

                        // Playlists section
                        if !vm.playlists.isEmpty {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("Playlists")
                                    .font(.title3)
                                    .padding(.horizontal, 50)

                                LazyVGrid(columns: columns, spacing: 50) {
                                    ForEach(vm.playlists) { playlist in
                                        NavigationLink(value: playlist) {
                                            PlaylistCardView(playlist: playlist)
                                        }
                                        .buttonStyle(.card)
                                    }
                                }
                                .padding(.horizontal, 50)
                            }
                        }

                        // Videos grid
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Videos")
                                .font(.title3)
                                .padding(.horizontal, 50)

                            LazyVGrid(columns: columns, spacing: 50) {
                                ForEach(vm.videos, id: \.stableId) { video in
                                    Button {
                                        if didLongPress { didLongPress = false; return }
                                        PlayerPresenter.shared.play(
                                            videoId: video.stableId,
                                            apiClient: session.apiClient,
                                            accessToken: session.tokenStore.accessToken,
                                            accountId: session.playbackAccountId
                                        )
                                    } label: {
                                        VideoCardView(video: video)
                                    }
                                    .buttonStyle(.card)
                                    .videoTilePlaylistPicker(video: video)
                                    .focused($channelGridFocusVideoId, equals: video.stableId)
                                    .id(channelCellScrollId(videoId: video.stableId))
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.5)
                                            .onEnded { _ in
                                                didLongPress = true
                                                detailVideoId = video.stableId
                                                showDetail = true
                                            }
                                    )
                                    .onAppear {
                                        if video.stableId == vm.videos.last?.stableId {
                                            Task { await vm.loadMoreVideos() }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 50)
                        }
                    }
                } else if let error = vm.errorMessage {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .peerTVPlayerDismissed)) { note in
                guard !showDetail else { return }
                guard let id = note.userInfo?["videoId"] as? String else { return }
                guard vm.videos.contains(where: { $0.stableId == id }) else { return }
                pendingFocusVideoId = id
                restoreChannelGridFocus(using: scrollProxy)
            }
            .onAppear {
                isChannelGridOnScreen = true
                restoreChannelGridFocus(using: scrollProxy)
            }
            .onDisappear {
                isChannelGridOnScreen = false
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(videoId: detailVideoId)
        }
        .task {
            vm.configure(
                apiClient: session.apiClient,
                isAuthenticated: session.phase == .authenticated,
                currentUsername: session.username.isEmpty ? nil : session.username
            )
            await vm.loadInitialIfEmpty()
            await vm.checkSubscription()
        }
    }

    private func restoreChannelGridFocus(using scrollProxy: ScrollViewProxy) {
        guard isChannelGridOnScreen, let id = pendingFocusVideoId else { return }
        pendingFocusVideoId = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            channelGridFocusVideoId = id
            withAnimation(.easeOut(duration: 0.25)) {
                scrollProxy.scrollTo(channelCellScrollId(videoId: id), anchor: .center)
            }
        }
    }
}
