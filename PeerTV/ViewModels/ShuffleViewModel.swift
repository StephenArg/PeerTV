import Foundation

@MainActor
final class ShuffleViewModel: ObservableObject {
    @Published var videos: [Video] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var apiClient: PeerTubeAPIClient?

    func configure(apiClient: PeerTubeAPIClient) {
        self.apiClient = apiClient
    }

    func loadRandom() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let randomVideos: [RandomVideo] = try await apiClient.request(.randomVideos)
            let existingIds = Set(videos.map(\.stableId))
            let converted = randomVideos
                .map { $0.toVideo() }
                .filter { !existingIds.contains($0.stableId) }
            videos.append(contentsOf: converted)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        videos = []
        await loadRandom()
    }
}
