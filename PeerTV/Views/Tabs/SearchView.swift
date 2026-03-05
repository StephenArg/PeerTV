import SwiftUI

struct SearchView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = SearchViewModel()
    @State private var searchText = ""
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var didLongPress = false

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 20) {
                    TextField("Search videos…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .padding(20)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .onSubmit {
                            Task { await vm.search(query: searchText) }
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            vm.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 50)

                if !vm.activeQuery.isEmpty {
                    if !vm.results.isEmpty {
                        Text("Results for \"\(vm.activeQuery)\"")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 50)
                    }

                    LazyVGrid(columns: columns, spacing: 50) {
                        ForEach(vm.results, id: \.stableId) { video in
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
                                if video.stableId == vm.results.last?.stableId {
                                    Task { await vm.loadMore() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 50)
                }

                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
        .overlay {
            if let error = vm.errorMessage, vm.results.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if !vm.isLoading && vm.results.isEmpty && !vm.activeQuery.isEmpty {
                ContentUnavailableView(
                    "No results for \"\(vm.activeQuery)\"",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term.")
                )
            } else if vm.activeQuery.isEmpty && !vm.isLoading {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 60))
                        .foregroundStyle(.tertiary)
                    Text("Search for videos across this instance")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Search")
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(videoId: detailVideoId)
        }
        .task {
            vm.configure(apiClient: session.apiClient)
        }
    }
}
