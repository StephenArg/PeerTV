import SwiftUI

struct SearchView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = SearchViewModel()
    @State private var searchText = ""
    @State private var detailVideoId: String = ""
    @State private var detailOriginHost: String?
    @State private var showDetail = false
    @State private var didLongPress = false
    /// Defer building `.searchable` until the full-screen cover has painted (avoids a flash of system search chrome).
    @State private var isContentReady = false

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if isContentReady {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        Picker("Search scope", selection: $vm.mode) {
                            ForEach(SearchMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 50)
                        .onChange(of: vm.mode) { _, _ in
                            vm.modeDidChange(draftQuery: searchText)
                        }

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
                                        let ctx = vm.playbackContext(
                                            for: video,
                                            accessToken: session.tokenStore.accessToken
                                        )
                                        PlayerPresenter.shared.play(
                                            videoId: video.stableId,
                                            apiClient: ctx.client,
                                            accessToken: ctx.accessToken,
                                            accountId: session.activeAccountId
                                        )
                                    } label: {
                                        VideoCardView(
                                            video: video,
                                            showOriginHost: vm.mode == .global
                                        )
                                    }
                                    .buttonStyle(.card)
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.5)
                                            .onEnded { _ in
                                                didLongPress = true
                                                detailVideoId = video.stableId
                                                detailOriginHost = vm.mode == .global ? video.originHost : nil
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
                    .padding(.top, 24)
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
                            Text(vm.mode.emptyStateMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 80)
                        }
                    }
                }
                .navigationTitle("Search")
                .searchable(text: $searchText, prompt: "Search videos…")
                .searchSuggestions {
                    if !trimmedSearchText.isEmpty {
                        ForEach(vm.suggestions) { suggestion in
                            suggestionRow(suggestion)
                                .searchCompletion(suggestion.query)
                        }
                    }
                }
                .onChange(of: searchText) { _, newValue in
                    vm.scheduleSearch(query: newValue)
                }
                .onSubmit(of: .search) {
                    let query = trimmedSearchText
                    guard !query.isEmpty else { return }
                    Task { await vm.search(query: query) }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .navigationDestination(isPresented: $showDetail) {
                    VideoDetailView(videoId: detailVideoId, originHost: detailOriginHost)
                }
            }
            .background(Color.black)
            }
        }
        .presentationBackground(.black)
        .onAppear {
            isContentReady = false
            DispatchQueue.main.async {
                isContentReady = true
            }
        }
        .onDisappear {
            isContentReady = false
        }
        .task {
            vm.configure(instanceClient: session.apiClient)
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: SearchSuggestion) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if let subtitle = suggestion.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
