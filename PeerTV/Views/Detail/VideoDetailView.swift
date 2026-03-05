import SwiftUI

struct VideoDetailView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm: VideoDetailViewModel
    @State private var showDebugJSON = false
    @State private var showPlaylistPicker = false

    init(videoId: String) {
        _vm = StateObject(wrappedValue: VideoDetailViewModel(videoId: videoId))
    }

    var body: some View {
        ScrollView {
            if vm.isLoading && vm.video == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 200)
            } else if let video = vm.video {
                HStack(alignment: .top, spacing: 50) {
                    // Left: preview + play + control bar
                    VStack(spacing: 24) {
                        ZStack {
                            CachedAsyncImage(
                                url: session.thumbnailURL(path: video.previewPath ?? video.thumbnailPath)
                            )
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipped()
                            .cornerRadius(16)

                            Button {
                                PlayerPresenter.shared.play(
                                    videoId: vm.videoId,
                                    apiClient: session.apiClient,
                                    accessToken: session.tokenStore.accessToken
                                )
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 80))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 10)
                            }
                            .buttonStyle(.plain)
                        }

                        if session.tokenStore.accessToken != nil {
                            controlBar(video: video)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Right: metadata
                    VStack(alignment: .leading, spacing: 20) {
                        Text(video.name ?? "Untitled")
                            .font(.title2)
                            .bold()

                        HStack(spacing: 14) {
                            ChannelAvatarView(
                                url: session.thumbnailURL(
                                    path: video.channel?.avatars?.first?.path
                                          ?? video.account?.avatars?.first?.path
                                )
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

                        Divider().padding(.vertical, 4)

                        if let desc = video.description, !desc.isEmpty {
                            Text(desc)
                                .font(.body)
                                .lineLimit(12)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        if DebugFlags.showAPIExplorer {
                            Button("Show Raw JSON") {
                                showDebugJSON = true
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(60)
            } else if let error = vm.errorMessage {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .sheet(isPresented: $showDebugJSON) {
            DebugRawJSONView(title: vm.video?.name ?? "Video", json: vm.rawJSON ?? "No data")
        }
        .sheet(isPresented: $showPlaylistPicker) {
            PlaylistPickerView(vm: vm)
        }
        .task {
            vm.configure(apiClient: session.apiClient, accountName: session.username.isEmpty ? nil : session.username)
            await vm.load()
            if session.tokenStore.accessToken != nil {
                await vm.loadUserRating()
            }
        }
        .onChange(of: vm.playlistMessage) { message in
            if let message {
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    vm.playlistMessage = nil
                }
            }
        }
    }

    // MARK: - Control Bar

    @ViewBuilder
    private func controlBar(video: Video) -> some View {
        HStack(spacing: 24) {
            Button {
                Task { await vm.toggleLike() }
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
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .buttonStyle(.card)

            Button {
                Task { await vm.toggleDislike() }
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
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .buttonStyle(.card)

            Button {
                Task { await vm.loadMyPlaylists() }
                showPlaylistPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.badge.plus")
                    Text("Save")
                }
                .font(.callout)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .buttonStyle(.card)
        }
        .overlay(
            Group {
                if let message = vm.playlistMessage {
                    Text(message)
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .transition(.opacity)
                        .offset(y: 50)
                }
            },
            alignment: .bottom
        )
        .animation(.easeInOut, value: vm.playlistMessage)
    }
}

// MARK: - Playlist Picker

struct PlaylistPickerView: View {
    @ObservedObject var vm: VideoDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.myPlaylists.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading playlists…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(vm.myPlaylists) { playlist in
                                Button {
                                    guard let playlistId = playlist.id else { return }
                                    Task {
                                        await vm.addToPlaylist(playlistId)
                                        dismiss()
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
                                    }
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 18)
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 40)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
        }
        .task {
            if vm.myPlaylists.isEmpty {
                await vm.loadMyPlaylists()
            }
        }
    }
}
