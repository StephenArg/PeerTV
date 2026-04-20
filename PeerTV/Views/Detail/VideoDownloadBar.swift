import SwiftUI

struct VideoDownloadBar: View {
    let video: Video
    @EnvironmentObject private var session: SessionStore
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var showQualityPicker = false
    @State private var selectedFile: VideoFile?
    @State private var selectedQualityLabel: String?

    private struct DownloadableFile: Identifiable {
        let file: VideoFile
        let label: String
        var id: String { label }
    }

    private var downloadableFiles: [DownloadableFile] {
        var results: [DownloadableFile] = []

        if let webFiles = video.files, !webFiles.isEmpty {
            for file in webFiles {
                guard let resId = file.resolution?.id, resId > 0,
                      let label = file.resolution?.label else { continue }
                guard file.fileDownloadUrl != nil || file.fileUrl != nil else { continue }
                results.append(DownloadableFile(file: file, label: label))
            }
        }

        if results.isEmpty, let hlsFiles = video.streamingPlaylists?.first?.files {
            for file in hlsFiles {
                guard let resId = file.resolution?.id, resId > 0,
                      let label = file.resolution?.label else { continue }
                guard file.fileDownloadUrl != nil || file.fileUrl != nil || file.playlistUrl != nil else { continue }
                results.append(DownloadableFile(file: file, label: label))
            }
        }

        return results.sorted { ($0.file.resolution?.id ?? 0) > ($1.file.resolution?.id ?? 0) }
    }

    var body: some View {
        let videoId = video.stableId

        if let progress = downloadManager.activeDownloads[videoId] {
            downloadingView(progress: progress, videoId: videoId)
        } else if downloadManager.isDownloaded(videoId) {
            downloadedView(videoId: videoId)
        } else if !downloadableFiles.isEmpty {
            notDownloadedView()
        }
    }

    // MARK: - States

    @ViewBuilder
    private func notDownloadedView() -> some View {
        let files = downloadableFiles
        let file = selectedFile ?? files.first?.file
        let label = selectedQualityLabel ?? files.first?.label ?? ""

        HStack(spacing: 32) {
            Button {
                guard let file else { return }
                downloadManager.startDownload(
                    video: video,
                    file: file,
                    qualityLabel: label,
                    accessToken: session.tokenStore.accessToken,
                    apiClient: session.apiClient
                )
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                    Text("Download")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.card)
            .frame(maxWidth: .infinity)

            Button {
                showQualityPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                    Text(label)
                    if let size = file?.size, size > 0 {
                        Text("(\(Self.formatBytes(Int64(size))))")
                            .foregroundStyle(.secondary)
                    }
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
        .confirmationDialog("Select Quality", isPresented: $showQualityPicker, titleVisibility: .visible) {
            ForEach(downloadableFiles, id: \.label) { entry in
                let sizeLabel = entry.file.size.map { Self.formatBytes(Int64($0)) } ?? ""
                let check = selectedQualityLabel == entry.label ? " \u{2713}" : ""
                Button("\(entry.label) \(sizeLabel)\(check)") {
                    selectedFile = entry.file
                    selectedQualityLabel = entry.label
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func downloadingView(progress: DownloadProgress, videoId: String) -> some View {
        Button {
            downloadManager.cancelDownload(videoId: videoId)
        } label: {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Downloading")
                            .font(.callout)
                        Spacer(minLength: 20)
                        if progress.totalBytes > 0 {
                            Text("\(Self.formatBytes(progress.receivedBytes)) / \(Self.formatBytes(progress.totalBytes))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if progress.bytesPerSecond > 0 {
                            Text(Self.formatSpeed(progress.bytesPerSecond))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 100, alignment: .trailing)
                        }
                    }

                    ProgressView(value: progress.fractionCompleted)
                        .progressViewStyle(.linear)
                }

                Image(systemName: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.card)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func downloadedView(videoId: String) -> some View {
        if let entry = downloadManager.downloadedVideos.first(where: { $0.videoId == videoId }) {
            HStack(spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Downloaded")
                    Text("\(entry.qualityLabel) - \(Self.formatBytes(entry.fileSize))")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                Spacer()

                Button {
                    downloadManager.removeDownload(videoId: videoId)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                        Text("Remove")
                    }
                    .font(.callout)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.card)
            }
        }
    }

    // MARK: - Helpers

    static func formatBytes(_ bytes: Int64) -> String {
        fixedDecimalBytes(Double(bytes))
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        "\(fixedDecimalBytes(bytesPerSecond))/s"
    }

    private static func fixedDecimalBytes(_ value: Double) -> String {
        let units: [(String, Double)] = [
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("KB", 1_000),
        ]
        for (label, threshold) in units {
            if value >= threshold {
                return String(format: "%.1f %@", value / threshold, label)
            }
        }
        return String(format: "%.0f bytes", value)
    }
}
