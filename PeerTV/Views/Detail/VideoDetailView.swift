import SwiftUI

struct VideoDetailView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: VideoDetailViewModel
    @StateObject private var playlistPickerVM = PlaylistPickerViewModel()
    @State private var showDebugJSON = false
    @State private var showPlaylistPicker = false
    @State private var descriptionExpanded = false
    @State private var savedPosition: TimeInterval?
    @State private var showAnonymousRestriction = false
    @State private var deletionGrant: VideoDeletionGrant?
    @State private var showDeleteConfirm = false
    @State private var showDeleteError = false

    private let originHost: String?
    private let commentReadHost: String?

    init(videoId: String, originHost: String? = nil, commentReadHost: String? = nil) {
        self.originHost = originHost
        self.commentReadHost = commentReadHost
        _vm = StateObject(wrappedValue: VideoDetailViewModel(videoId: videoId, originHost: originHost))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { scrollProxy in
                ScrollView {
                if vm.isLoading && vm.video == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 200)
                } else if let video = vm.video {
                    let resumeAt = PlaybackPositionStore.effectiveResumePosition(
                        stored: savedPosition,
                        durationSeconds: video.duration
                    )
                    HStack(alignment: .top, spacing: 50) {
                        // Left: preview + play + control bar
                        VStack(spacing: 24) {
                            // Full preview is one focus target so moving up from the control bar always
                            // lands on play (same width as the row below).
                            Button {
                                let tileURLs = historyTileURLs(for: video)
                                PlayerPresenter.shared.play(
                                    videoId: vm.videoId,
                                    apiClient: playbackAPIClient,
                                    accessToken: playbackAccessToken,
                                    apiHosts: vm.usesFederatedOrigin ? federatedAPIHosts : nil,
                                    accountId: session.playbackAccountId,
                                    historyTileThumbnailURL: tileURLs.thumbnail,
                                    historyTileChannelAvatarURL: tileURLs.avatar
                                )
                            } label: {
                                ZStack {
                                    CachedAsyncImage(
                                        url: detailAssetURL(path: video.previewPath ?? video.thumbnailPath)
                                    )
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .clipped()

                                    VStack(spacing: 12) {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 80))
                                            .foregroundStyle(.white)
                                            .shadow(radius: 10)

                                        if let pos = resumeAt {
                                            Text("Resume at \(formatTime(pos))")
                                                .font(.callout)
                                                .fontWeight(.medium)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .background(.ultraThinMaterial, in: Capsule())
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.card)
                            .accessibilityLabel(resumeAt != nil ? "Resume video" : "Play video")

                            if resumeAt != nil {
                                Button {
                                    if let accountId = session.playbackAccountId {
                                        PlaybackPositionStore.remove(videoId: vm.videoId, accountId: accountId)
                                        savedPosition = nil
                                    }
                                    let tileURLs = historyTileURLs(for: video)
                                    PlayerPresenter.shared.play(
                                        videoId: vm.videoId,
                                        apiClient: playbackAPIClient,
                                        accessToken: playbackAccessToken,
                                        apiHosts: vm.usesFederatedOrigin ? federatedAPIHosts : nil,
                                        accountId: session.playbackAccountId,
                                        historyTileThumbnailURL: tileURLs.thumbnail,
                                        historyTileChannelAvatarURL: tileURLs.avatar
                                    )
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.counterclockwise")
                                        Text("Start from beginning")
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 14)
                                }
                                .buttonStyle(.card)
                            }

                            if showsAccountActions {
                                controlBar(video: video)
                            }

                            VideoDownloadBar(
                                video: video,
                                onAnonymousRestricted: { showAnonymousRestriction = true }
                            )

                            Divider()
                                .padding(.top, 8)

                            VideoCommentsSection(
                                vm: vm,
                                postingBlocked: session.isAnonymous,
                                onPostingBlocked: { showAnonymousRestriction = true }
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .focusSection()

                        // Right: metadata
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 20) {
                                Text(video.name ?? "Untitled")
                                    .font(.title2)
                                    .bold()
                                    .multilineTextAlignment(.leading)

                                HStack(spacing: 14) {
                                    ChannelAvatarView(
                                        url: detailAvatarURL(for: video)
                                    )
                                    .frame(width: 52, height: 52)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(video.channel?.displayName ?? video.account?.displayName ?? "")
                                            .font(.callout)
                                            .fontWeight(.medium)

                                        if let host = video.channel?.host ?? video.account?.host {
                                            Text(host)
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }

                            HStack(spacing: 24) {
                                if let views = video.views {
                                    Label("\(views) views", systemImage: "eye")
                                }
                                if !video.formattedDuration.isEmpty {
                                    Label(video.formattedDuration, systemImage: "clock")
                                }
                                if let likes = video.likes {
                                    Label("\(likes)", systemImage: "hand.thumbsup")
                                }
                                if let date = video.relativeDate {
                                    Label(date, systemImage: "calendar")
                                }
                                if let privacyLabel = video.privacy?.label {
                                    Label(privacyLabel, systemImage: "lock")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if let desc = video.description, !desc.isEmpty {
                                Button {
                                    descriptionExpanded.toggle()
                                } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(desc)
                                            .font(.body)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(descriptionExpanded ? nil : 5)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)

                                        Text(descriptionExpanded ? "Show Less" : "Show More")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 8)
                                }
                                .buttonStyle(.card)
                                .accessibilityHint(descriptionExpanded ? "Collapses the description" : "Expands the full description")
                            }

                            if (DebugFlags.showAPIExplorer && DebugFlags.showVideoDetailRawJSON)
                                || deletionGrant != nil {
                                Divider().padding(.vertical, 4)

                                HStack(spacing: 24) {
                                    if DebugFlags.showAPIExplorer && DebugFlags.showVideoDetailRawJSON {
                                        Button("Show Raw JSON") {
                                            showDebugJSON = true
                                        }
                                        .font(.caption)
                                    }

                                    if deletionGrant != nil {
                                        Button {
                                            showDeleteConfirm = true
                                        } label: {
                                            if vm.isDeleting {
                                                ProgressView()
                                            } else {
                                                Text("Delete")
                                            }
                                        }
                                        .font(.caption)
                                        .disabled(vm.isDeleting)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                    }
                    .padding(60)
                    .padding(.bottom, 80)
                    .id("videoDetailScrollAnchor")
                } else if let error = vm.errorMessage {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                }
                }
                .scrollIndicators(.visible)
                .onChange(of: descriptionExpanded) { _, expanded in
                    guard !expanded else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollProxy.scrollTo("videoDetailScrollAnchor", anchor: .top)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .sheet(isPresented: $showDebugJSON) {
            DebugRawJSONView(title: vm.video?.name ?? "Video", json: vm.rawJSON ?? "No data")
        }
        .sheet(isPresented: $showPlaylistPicker) {
            PlaylistPickerView(vm: playlistPickerVM)
        }
        .confirmationDialog(
            "Delete this video? This cannot be undone.",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Could not delete video", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.deleteError ?? "Unknown error.")
        }
        .task {
            let client = detailAPIClient
            let federated = vm.usesFederatedOrigin
            let homeHost = session.baseURL?.host?.lowercased()
            let extraPostHosts = [commentReadHost, originHost]
                .compactMap { raw in
                    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .filter { homeHost == nil || $0.lowercased() != homeHost }
            let additionalCommentClients = federated
                ? session.authenticatedClients(forHosts: extraPostHosts)
                : []
            vm.configure(
                apiClient: client,
                commentClient: federated ? session.apiClient : client,
                commentReadHost: commentReadHost,
                additionalCommentClients: additionalCommentClients,
                accountName: federated ? nil : (session.username.isEmpty ? nil : session.username),
                canPostComments: session.isAnonymous || session.tokenStore.accessToken != nil
            )
            refreshSavedPosition()
            await vm.load()
            if let video = vm.video {
                deletionGrant = await session.resolveVideoDeletionGrant(for: video)
            } else {
                deletionGrant = nil
            }
            if !federated, session.tokenStore.accessToken != nil {
                await vm.loadUserRating()
            }
            await vm.loadComments()
            if !federated, session.tokenStore.accessToken != nil {
                playlistPickerVM.configure(
                    apiClient: session.apiClient,
                    accountName: session.username.isEmpty ? nil : session.username,
                    numericVideoId: vm.video?.id
                )
            }
        }
        .onAppear {
            refreshSavedPosition()
        }
        .anonymousRestrictionAlert(isPresented: $showAnonymousRestriction) {
            session.exitAnonymousToLogin()
        }
    }

    // MARK: - Helpers

    private var showsAccountActions: Bool {
        session.isAnonymous || session.tokenStore.accessToken != nil
    }

    private func guardAuthenticatedAction(_ action: () -> Void) {
        if session.isAnonymous {
            showAnonymousRestriction = true
        } else {
            action()
        }
    }

    private var detailAPIClient: PeerTubeAPIClient {
        if let first = federatedAPIHosts.first {
            return PeerTubeOriginClients.publicClient(forHost: first)
        }
        return session.apiClient
    }

    private var federatedAPIHosts: [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for raw in [commentReadHost, originHost] {
            let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            hosts.append(key)
        }
        return hosts
    }

    private var playbackAPIClient: PeerTubeAPIClient {
        vm.configuredAPIClient ?? detailAPIClient
    }

    private var playbackAccessToken: String? {
        vm.usesFederatedOrigin ? nil : session.tokenStore.accessToken
    }

    private func detailAssetURL(path: String?) -> URL? {
        PeerTubeAssetURL.resolve(
            path: path,
            instanceBase: session.baseURL,
            federatedHost: vm.usesFederatedOrigin ? (originHost ?? vm.video?.originHost) : nil,
            cacheHost: vm.usesFederatedOrigin ? (commentReadHost ?? federatedAPIHosts.first) : nil
        )
    }

    /// Preview URLs currently shown on the detail screen (for anonymous history capture).
    private func historyTileURLs(for video: Video) -> (thumbnail: URL?, avatar: URL?) {
        (
            detailAssetURL(path: video.previewPath ?? video.thumbnailPath),
            detailAvatarURL(for: video)
        )
    }

    private func detailAvatarURL(for video: Video) -> URL? {
        let assetCacheHost: String? = {
            if vm.usesFederatedOrigin {
                return commentReadHost ?? federatedAPIHosts.first
            }
            return session.baseURL?.host
        }()
        return PeerTubeAssetURL.resolve(
            avatars: video.channel?.avatars ?? video.account?.avatars,
            instanceBase: session.baseURL,
            federatedHost: vm.usesFederatedOrigin ? (originHost ?? video.originHost) : nil,
            cacheHost: assetCacheHost
        )
    }

    private func refreshSavedPosition() {
        if let accountId = session.playbackAccountId {
            savedPosition = PlaybackPositionStore.position(for: vm.videoId, accountId: accountId)
        } else {
            savedPosition = nil
        }
    }

    private func performDelete() async {
        guard let grant = deletionGrant else { return }
        let uuid = vm.video?.uuid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let videoId = (uuid?.isEmpty == false) ? (uuid ?? vm.videoId) : vm.videoId
        let ok = await vm.deleteVideo(using: grant.client, videoId: videoId)
        if ok {
            dismiss()
        } else {
            showDeleteError = true
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Control Bar

    @ViewBuilder
    private func controlBar(video: Video) -> some View {
        HStack(spacing: 32) {
            Button {
                guardAuthenticatedAction { Task { await vm.toggleLike() } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: vm.userRating == "like" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .foregroundStyle(vm.userRating == "like" ? Color.accentColor : .primary)
                    if let likes = video.likes {
                        Text("\(likes)")
                    }
                }
                .font(.callout)
                .fontWeight(vm.userRating == "like" ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.card)
            .frame(maxWidth: .infinity)

            Button {
                guardAuthenticatedAction { Task { await vm.toggleDislike() } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: vm.userRating == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .foregroundStyle(vm.userRating == "dislike" ? Color.accentColor : .primary)
                    if let dislikes = video.dislikes {
                        Text("\(dislikes)")
                    }
                }
                .font(.callout)
                .fontWeight(vm.userRating == "dislike" ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.card)
            .frame(maxWidth: .infinity)

            Button {
                guardAuthenticatedAction {
                    showPlaylistPicker = true
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.badge.plus")
                    Text("Save")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.card)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Playlist Picker

private struct PlaylistPickerToastBanner: View {
    let message: String

    var body: some View {
        let isSuccess = message == PlaylistPickerViewModel.addedMessage
            || message == PlaylistPickerViewModel.removedMessage
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
            Text(message)
                .font(.callout)
                .fontWeight(.semibold)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSuccess ? Color.green.opacity(0.94) : Color.red.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .padding(.horizontal, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct PlaylistPickerView: View {
    @ObservedObject var vm: PlaylistPickerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showNewPlaylistPrompt = false

    var body: some View {
        NavigationStack {
            Group {
                if !vm.myPlaylistsLoaded {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading playlists…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            if vm.myPlaylists.isEmpty {
                                Text("You do not have any playlists yet.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 30)
                                    .padding(.bottom, 8)
                            }
                            ForEach(vm.myPlaylists) { playlist in
                                Button {
                                    Task {
                                        await vm.togglePlaylistMembership(for: playlist)
                                    }
                                } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: "list.and.film")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 48)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(playlist.displayName ?? "Untitled")
                                                .font(.body)
                                            if let count = playlist.videosLength {
                                                Text("\(count) videos")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        if vm.isVideoInPlaylist(playlist) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 18)
                                }
                                .buttonStyle(.card)
                            }

                            Button {
                                showNewPlaylistPrompt = true
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Create new playlist")
                                            .font(.body)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 30)
                                .padding(.vertical, 18)
                            }
                            .buttonStyle(.card)
                        }
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 60)
                        .padding(.vertical, 40)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .sheet(isPresented: $showNewPlaylistPrompt) {
                NewPlaylistNamePromptView(title: "New Playlist") { name in
                    await vm.createPlaylistAndAddVideo(displayName: name)
                } onSuccess: {
                    dismiss()
                }
            }
        }
        // Fills the screen with a dark backdrop. Needed when presented over the player (an
        // over-full-screen host with a clear background); harmless behind the detail-screen sheet.
        .background(Color.black.opacity(0.9).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let message = vm.playlistMessage {
                PlaylistPickerToastBanner(message: message)
                    .padding(.bottom, 48)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: vm.playlistMessage)
        .onChange(of: vm.playlistMessage) { _, message in
            if message != nil {
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    vm.playlistMessage = nil
                }
            }
        }
        .task {
            await vm.loadMyPlaylists()
        }
    }
}
