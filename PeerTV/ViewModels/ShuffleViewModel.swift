import Foundation

@MainActor
final class ShuffleViewModel: ObservableObject {
    @Published var videos: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var apiClient: PeerTubeAPIClient?
    private var instanceURL: URL?

    func configure(apiClient: PeerTubeAPIClient, instanceURL: URL?) {
        self.apiClient = apiClient
        self.instanceURL = instanceURL
    }

    func loadRandom() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let randomVideos: [RandomVideo] = try await apiClient.request(.randomVideos)
            let existingIds = Set(videos.map(\.stableId))
            var converted = randomVideos
                .map { $0.toVideo(instanceURL: instanceURL) }
                .filter { !existingIds.contains($0.stableId) }
            converted = await Self.enrichChannelAvatars(converted, apiClient: apiClient)
            videos.append(contentsOf: converted)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        videos = []
        await loadRandom()
    }

    /// Plugin rows omit `avatars`; resolve them via the same channel API as other tabs.
    private static func enrichChannelAvatars(_ videos: [Video], apiClient: PeerTubeAPIClient) async -> [Video] {
        var handleToIndices: [String: [Int]] = [:]
        for (idx, v) in videos.enumerated() {
            guard let handle = channelHandle(for: v) else { continue }
            if let avatars = v.channel?.avatars, !avatars.isEmpty { continue }
            handleToIndices[handle, default: []].append(idx)
        }
        guard !handleToIndices.isEmpty else { return videos }
        var out = videos
        for (handle, indices) in handleToIndices {
            do {
                let ch: VideoChannel = try await apiClient.request(.channelDetail(handle: handle))
                guard let avatars = ch.avatars, !avatars.isEmpty else { continue }
                for i in indices {
                    out[i] = out[i].withChannelAvatars(avatars)
                }
            } catch {
                continue
            }
        }
        return out
    }

    private static func channelHandle(for video: Video) -> String? {
        guard let name = video.channel?.name, !name.isEmpty else { return nil }
        if let host = video.channel?.host, !host.isEmpty {
            return "\(name)@\(host)"
        }
        return name
    }
}
