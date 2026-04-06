import SwiftUI

struct DownloadedVideosView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var editMode = false
    @State private var showRemoveAllConfirmation = false
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var didLongPress = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 20) {
                    Text("Downloaded Videos")
                        .font(.title3)
                        .bold()

                    Spacer()

                    if !downloadManager.downloadedVideos.isEmpty {
                        Button {
                            editMode.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: editMode ? "checkmark" : "pencil")
                                Text(editMode ? "Done" : "Remove")
                            }
                            .font(.callout)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.card)

                        Button {
                            showRemoveAllConfirmation = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "trash")
                                Text("Remove All")
                            }
                            .font(.callout)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.card)
                    }
                }

                if downloadManager.downloadedVideos.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Videos you download will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(downloadManager.downloadedVideos) { video in
                            downloadRow(video)
                        }
                    }
                }
            }
            .padding(.horizontal, 50)
            .padding(.top, 40)
            .padding(.bottom, 120)
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(videoId: detailVideoId)
        }
        .confirmationDialog(
            "Remove all downloaded videos?",
            isPresented: $showRemoveAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                downloadManager.removeAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func downloadRow(_ video: DownloadedVideo) -> some View {
        Button {
            if didLongPress { didLongPress = false; return }
            if editMode {
                downloadManager.removeDownload(videoId: video.videoId)
            } else {
                PlayerPresenter.shared.play(
                    videoId: video.videoId,
                    apiClient: session.apiClient,
                    accessToken: session.tokenStore.accessToken
                )
            }
        } label: {
            HStack(spacing: 20) {
                ZStack(alignment: .bottomLeading) {
                    if let thumbPath = video.thumbnailPath {
                        CachedAsyncImage(
                            url: session.thumbnailURL(path: thumbPath)
                        )
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(width: 200, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 200, height: 112)
                            .overlay {
                                Image(systemName: "film")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            }
                    }

                    if !editMode {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.6))
                            .clipShape(Circle())
                            .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.name)
                        .font(.body)
                        .lineLimit(2)

                    if let channel = video.channelName {
                        Text(channel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        Text(video.qualityLabel)
                        Text(VideoDownloadBar.formatBytes(video.fileSize))
                        if let duration = video.duration, duration > 0 {
                            Text(formatDuration(duration))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    Text(video.downloadedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if editMode {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    didLongPress = true
                    detailVideoId = video.videoId
                    showDetail = true
                }
        )
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
