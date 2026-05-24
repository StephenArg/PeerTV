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
    @State private var hasFocusedSearchField = false
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var searchGridFocusVideoId: String?

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    private func searchCellScrollId(videoId: String) -> String {
        "searchCell-\(videoId)"
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsSuggestions: Bool {
        !trimmedSearchText.isEmpty
            && vm.results.isEmpty
            && !vm.isLoading
            && !vm.suggestions.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                searchHeader

                ScrollViewReader { scrollProxy in
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

                        if showsSuggestions {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(vm.suggestions) { suggestion in
                                    Button {
                                        searchText = suggestion.query
                                        Task { await vm.search(query: suggestion.query) }
                                    } label: {
                                        suggestionRow(suggestion)
                                            .padding(.horizontal, 50)
                                            .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
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
                                    .focused($searchGridFocusVideoId, equals: video.stableId)
                                    .id(searchCellScrollId(videoId: video.stableId))
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
                .onReceive(NotificationCenter.default.publisher(for: .peerTVPlayerDismissed)) { note in
                    guard let id = note.userInfo?["videoId"] as? String else { return }
                    guard vm.results.contains(where: { $0.stableId == id }) else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        searchGridFocusVideoId = id
                        withAnimation(.easeOut(duration: 0.25)) {
                            scrollProxy.scrollTo(searchCellScrollId(videoId: id), anchor: .center)
                        }
                    }
                }
                }
                .overlay {
                    if let error = vm.errorMessage, vm.results.isEmpty {
                        ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                    } else if !vm.isLoading && vm.results.isEmpty && !vm.activeQuery.isEmpty && !showsSuggestions {
                        ContentUnavailableView(
                            "No results for \"\(vm.activeQuery)\"",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search term.")
                        )
                    } else if vm.activeQuery.isEmpty && !vm.isLoading && !showsSuggestions {
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
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showDetail) {
                VideoDetailView(videoId: detailVideoId, originHost: detailOriginHost)
            }
        }
        .background(Color.black)
        .presentationBackground(.black)
        .onAppear {
            guard !hasFocusedSearchField else { return }
            hasFocusedSearchField = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                searchFieldFocused = true
            }
        }
        .task {
            vm.configure(instanceClient: session.apiClient)
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 24) {
            TextField("Search videos…", text: $searchText)
                .focused($searchFieldFocused)
                .onSubmit {
                    let query = trimmedSearchText
                    guard !query.isEmpty else { return }
                    Task { await vm.search(query: query) }
                }
                .onChange(of: searchText) { _, newValue in
                    vm.scheduleSearch(query: newValue)
                }

            Button("Close") { dismiss() }
        }
        .padding(.horizontal, 50)
        .padding(.top, 24)
        .padding(.bottom, 8)
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
