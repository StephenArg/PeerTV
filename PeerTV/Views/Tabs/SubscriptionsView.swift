import SwiftUI

struct SubscriptionsView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = SubscriptionsViewModel()
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var didLongPress = false

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Subscriptions")
                    .font(.title3)
                    .bold()
                    .padding(.horizontal, 50)

                if !vm.subscriptions.isEmpty {
                    VStack(alignment: .leading) {
                        Text("My Subscriptions")
                            .font(.headline)
                            .padding(.horizontal, 50)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 30) {
                                ForEach(vm.subscriptions) { sub in
                                    NavigationLink(value: sub) {
                                        VStack(spacing: 12) {
                                            ChannelAvatarView(
                                                url: session.thumbnailURL(
                                                    path: sub.avatars?.last?.path
                                                          ?? sub.ownerAccount?.avatars?.last?.path
                                                )
                                            )
                                            .frame(width: 80, height: 80)

                                            Text(sub.displayName ?? sub.name ?? "")
                                                .font(.caption)
                                                .lineLimit(1)
                                                .foregroundStyle(.primary)
                                        }
                                        .frame(width: 120)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                            .padding(.horizontal, 50)
                            .padding(.vertical, 30)
                        }
                    }
                }

                LazyVGrid(columns: columns, spacing: 50) {
                    ForEach(vm.feedVideos, id: \.stableId) { video in
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
                            if video.stableId == vm.feedVideos.last?.stableId {
                                Task { await vm.loadMoreFeed() }
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
            if let error = vm.errorMessage, vm.feedVideos.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
            if !vm.isLoading && vm.feedVideos.isEmpty && vm.errorMessage == nil {
                ContentUnavailableView("No subscription videos yet",
                                       systemImage: "bell.slash",
                                       description: Text("Subscribe to channels to see their videos here."))
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
