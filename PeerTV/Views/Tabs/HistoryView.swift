import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = HistoryViewModel()
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var didLongPress = false

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("History")
                    .font(.title3)
                    .bold()
                    .padding(.horizontal, 50)

                LazyVGrid(columns: columns, spacing: 50) {
                    ForEach(vm.videos, id: \.stableId) { video in
                        Button {
                            if didLongPress { didLongPress = false; return }
                            PlayerPresenter.shared.play(
                                videoId: video.stableId,
                                apiClient: session.apiClient,
                                accessToken: session.tokenStore.accessToken
                            )
                        } label: {
                            VideoCardView(video: video)
                        }
                        .buttonStyle(.card)
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
                                Task { await vm.loadMore() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 50)
            }
            .padding(.top, 40)
            .padding(.bottom, 60)

            if vm.isLoading {
                ProgressView().padding()
            }
        }
        .overlay {
            if let error = vm.errorMessage, vm.videos.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
            if !vm.isLoading && vm.videos.isEmpty && vm.errorMessage == nil {
                ContentUnavailableView("No watch history",
                                       systemImage: "clock",
                                       description: Text("Videos you watch will appear here."))
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(videoId: detailVideoId)
        }
        .task {
            vm.configure(apiClient: session.apiClient)
            await vm.loadInitial()
        }
    }
}
