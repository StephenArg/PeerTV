import SwiftUI

struct DownloadedVideosView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloadManager = DownloadManager.shared
    @AppStorage(DownloadsSort.defaultsKey) private var sort: DownloadsSort = .newest
    @State private var editMode = false
    @State private var showRemoveAllConfirmation = false
    @State private var showSortDialog = false
    /// True when shown as the Downloads tab, where there is nothing to go back to.
    var isTabRoot = false
    @State private var detailVideoId: String = ""
    @State private var showDetail = false

    /// Three cards per line, each a third of the width.
    private let columns = [
        GridItem(.flexible(), spacing: 30, alignment: .top),
        GridItem(.flexible(), spacing: 30, alignment: .top),
        GridItem(.flexible(), spacing: 30, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloads")
                            .font(.title3)
                            .bold()
                        if !downloadManager.downloadedVideos.isEmpty {
                            Text(downloadManager.downloadedVideos.storageSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if !downloadManager.downloadedVideos.isEmpty {
                        Button {
                            showSortDialog = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.up.arrow.down.circle")
                                Text(sort.displayName)
                                    .lineLimit(1)
                            }
                            .font(.callout)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.card)

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
                    VStack(spacing: 28) {
                        ContentUnavailableView(
                            "No Downloads",
                            systemImage: "arrow.down.circle",
                            description: Text("Videos you download will appear here.")
                        )
                        if !isTabRoot {
                            Button {
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "chevron.backward")
                                    Text("Back")
                                }
                                .font(.callout)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(sort.sorted(downloadManager.downloadedVideos)) { video in
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
        .confirmationDialog("Sort by", isPresented: $showSortDialog, titleVisibility: .visible) {
            ForEach(DownloadsSort.allCases) { option in
                Button(option == sort ? "\(option.displayName) ✓" : option.displayName) {
                    sort = option
                }
            }
            Button("Cancel", role: .cancel) {}
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
            if showDetail { return }
            if editMode {
                downloadManager.removeDownload(videoId: video.videoId)
            } else {
                PlayerPresenter.shared.play(
                    videoId: video.videoId,
                    apiClient: session.apiClient,
                    accessToken: session.tokenStore.accessToken,
                    accountId: session.activeAccountId
                )
            }
        } label: {
            HStack(spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    if let thumbPath = video.thumbnailPath {
                        CachedAsyncImage(
                            url: session.thumbnailURL(path: thumbPath)
                        )
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(width: 176, height: 99)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 176, height: 99)
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
                    // Always reserve two title lines so the cards in a row are the same height.
                    ZStack(alignment: .topLeading) {
                        Text(" \n ")
                            .font(.body)
                            .hidden()
                        Text(video.name)
                            .font(.body)
                            .lineLimit(2)
                    }

                    if let channel = video.channelName {
                        Text(channel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

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
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    // The release after a long press can still reach the tile button; `showDetail` makes it a no-op.
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
