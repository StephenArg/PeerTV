import SwiftUI

/// Info panel shown over the player: title, channel (subscribe, open), description, likes and
/// chapters, without leaving playback. Presented by `PlayerCoordinator` in a hosting controller;
/// the video keeps playing underneath, and Back closes the panel.
struct PlayerInfoPanelView: View {
    @ObservedObject var vm: VideoDetailViewModel
    /// Detail decoded when playback started, shown until `vm` has loaded its own copy.
    let placeholder: Video?
    let instanceBaseURL: URL?
    let chapters: [VideoChapter]
    let currentTime: TimeInterval
    let isSignedIn: Bool
    let isLive: Bool
    /// Chapter chosen: seek there and close the panel.
    let onSeek: (TimeInterval) -> Void
    /// "Go to Channel": closes the player and opens the channel page.
    let onOpenChannel: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var subscription = ChannelSubscriptionViewModel()
    @State private var didStartLoading = false

    private var video: Video? { vm.video ?? placeholder }

    private var channelHandle: String? {
        video.flatMap(VideoDetailViewModel.channelHandle(for:))
    }

    private var channelName: String {
        video?.channel?.displayName ?? video?.channel?.name ?? video?.account?.displayName ?? "Channel"
    }

    private var avatarURL: URL? {
        guard let video else { return nil }
        return PeerTubeAssetURL.resolve(
            avatars: video.channel?.avatars ?? video.account?.avatars,
            instanceBase: instanceBaseURL,
            federatedHost: video.originHost,
            preferredWidth: 120
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 60) {
                leftColumn
                    .frame(width: 640, alignment: .leading)
                    .focusSection()

                rightColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.top, 70)
            .padding(.bottom, 60)
        }
        .alert("Subscription", isPresented: Binding(
            get: { subscription.error != nil },
            set: { if !$0 { subscription.error = nil } }
        )) {
            Button("OK", role: .cancel) { subscription.error = nil }
        } message: {
            Text(subscription.error ?? "")
        }
        .task {
            guard !didStartLoading else { return }
            didStartLoading = true
            await vm.load()
            if isSignedIn {
                await vm.loadUserRating()
                if let apiClient = vm.configuredAPIClient, let handle = channelHandle {
                    subscription.configure(apiClient: apiClient, handle: handle)
                    await subscription.check()
                }
            }
        }
    }

    // MARK: Left: title, channel, stats, actions

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(video?.name ?? vm.errorMessage ?? "Loading…")
                .font(.title2)
                .bold()
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                ChannelAvatarView(url: avatarURL)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channelName)
                        .font(.headline)
                        .lineLimit(1)
                    if let host = video?.channel?.host, !host.isEmpty {
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if let video {
                statsRow(video)
            }

            if !vm.detailPills.isEmpty {
                VideoDetailPillsRow(pills: vm.detailPills)
            }

            VStack(alignment: .leading, spacing: 16) {
                if let handle = channelHandle {
                    HStack(spacing: 16) {
                        if isSignedIn {
                            Button {
                                Task { await subscription.toggle() }
                            } label: {
                                Label(subscription.isSubscribed ? "Subscribed" : "Subscribe",
                                      systemImage: subscription.isSubscribed ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.callout)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 14)
                            }
                            .buttonStyle(.card)
                            .disabled(subscription.isToggling)
                        }
                        Button {
                            onOpenChannel(handle)
                        } label: {
                            Label("Go to Channel", systemImage: "person.crop.rectangle")
                                .font(.callout)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.card)
                    }
                }

                if isSignedIn, let video, video.id != nil {
                    HStack(spacing: 16) {
                        ratingButton(
                            count: video.likes,
                            systemImage: vm.userRating == "like" ? "hand.thumbsup.fill" : "hand.thumbsup",
                            active: vm.userRating == "like"
                        ) { Task { await vm.toggleLike() } }
                        ratingButton(
                            count: video.dislikes,
                            systemImage: vm.userRating == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                            active: vm.userRating == "dislike"
                        ) { Task { await vm.toggleDislike() } }
                    }
                }
            }

            Spacer(minLength: 0)

            Text("Press Back to return to the video.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func statsRow(_ video: Video) -> some View {
        HStack(spacing: 24) {
            if isLive {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.red)
            }
            if let views = video.views {
                Label("\(views) views", systemImage: "eye")
            }
            if !isLive, !video.formattedDuration.isEmpty {
                Label(video.formattedDuration, systemImage: "clock")
            }
            if let date = video.relativeDate {
                Label(date, systemImage: "calendar")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func ratingButton(count: Int?, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(active ? Color.accentColor : .primary)
                if let count {
                    Text("\(count)")
                }
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(.card)
    }

    // MARK: Right: description and chapters

    private var rightColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let description = video?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                    // Focusable so the description can be scrolled with the remote.
                    Button {} label: {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.card)
                } else if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let error = vm.errorMessage, video == nil {
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if !chapters.isEmpty {
                    Text("Chapters")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    let currentIndex = chapters.chapterIndex(at: currentTime)
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        Button {
                            onSeek(chapter.timecode)
                        } label: {
                            HStack(spacing: 20) {
                                Text(TransportBarOverlayView.fmt(chapter.timecode))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(chapter.title)
                                    .lineLimit(1)
                                Spacer()
                                if index == currentIndex {
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.card)
                    }
                }
            }
            .padding(.trailing, 20)
            .padding(.bottom, 40)
        }
    }
}
