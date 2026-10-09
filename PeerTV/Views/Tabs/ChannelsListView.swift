import SwiftUI

struct ChannelsListView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.peerTVChannelsTabRefreshToken) private var channelsTabRefreshToken
    @StateObject private var vm = ChannelsViewModel()
    @State private var showSearch = false
    @State private var showSortDialog = false
    @State private var showScopeDialog = false

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 40)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .center, spacing: 28) {
                    Text("Channels")
                        .font(.title3)
                        .bold()
                        .lineLimit(1)
                        .layoutPriority(0)

                    HStack(spacing: 35) {
                        headerButton("Search", systemImage: "magnifyingglass") {
                            showSearch = true
                        }

                        if vm.showsSortControls {
                            headerButton("Sort", systemImage: "arrow.up.arrow.down.circle") {
                                showSortDialog = true
                            }
                        }

                        headerButton(vm.localOnly ? "This server" : "All servers", systemImage: "globe") {
                            showScopeDialog = true
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }
                .padding(.horizontal, 60)

                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(vm.channels) { channel in
                        NavigationLink(value: channel) {
                            ChannelCardView(channel: channel)
                        }
                        .buttonStyle(.card)
                        .onAppear {
                            if channel.id == vm.channels.last?.id {
                                Task { await vm.loadMore() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 60)
            }
            .padding(.top, 40)
            .padding(.bottom, 60)

            if vm.isLoading {
                ProgressView().padding()
            }
        }
        .overlay {
            if let error = vm.errorMessage, vm.channels.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            ChannelSearchView(localOnly: vm.localOnly)
                .environmentObject(session)
                .presentationBackground(.black)
        }
        .confirmationDialog("Sort by", isPresented: $showSortDialog, titleVisibility: .visible) {
            ForEach(ChannelListSort.dialogOrder) { option in
                Button(option == vm.sort ? "\(option.displayName) ✓" : option.displayName) {
                    Task { await vm.applySort(option) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Show channels from", isPresented: $showScopeDialog, titleVisibility: .visible) {
            Button(vm.localOnly ? "All servers" : "All servers ✓") {
                Task { await vm.applyLocalOnly(false) }
            }
            Button(vm.localOnly ? "This server only ✓" : "This server only") {
                Task { await vm.applyLocalOnly(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All servers includes channels this server follows elsewhere. This server only lists channels hosted here, newest first.")
        }
        .task {
            vm.configure(apiClient: session.apiClient, instanceHost: session.baseURL?.host)
            await vm.loadInitialIfEmpty()
        }
        .onChange(of: channelsTabRefreshToken) { _, _ in
            vm.configure(apiClient: session.apiClient, instanceHost: session.baseURL?.host)
            Task { await vm.refreshInPlace() }
        }
    }

    private func headerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .font(.callout)
            .padding(.horizontal, 48)
            .padding(.vertical, 12)
        }
        .buttonStyle(.card)
    }
}

// MARK: - Channel search

/// Full-screen channel search over the connected server (`GET /api/v1/search/video-channels`),
/// limited to channels hosted there when the Channels tab is set to "this server only".
struct ChannelSearchView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = ChannelSearchViewModel()
    @State private var searchText = ""
    /// Defer building `.searchable` until the full-screen cover has painted (avoids a flash of system search chrome).
    @State private var isContentReady = false
    let localOnly: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 40)
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
                            if !vm.activeQuery.isEmpty, !vm.results.isEmpty {
                                Text("Results for \"\(vm.activeQuery)\"")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 60)
                            }

                            LazyVGrid(columns: columns, spacing: 40) {
                                ForEach(vm.results) { channel in
                                    NavigationLink(value: channel) {
                                        ChannelCardView(channel: channel)
                                    }
                                    .buttonStyle(.card)
                                    .onAppear {
                                        if channel.id == vm.results.last?.id {
                                            Task { await vm.loadMore() }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 60)

                            if vm.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            }
                        }
                        .padding(.top, 24)
                        .padding(.bottom, 60)
                    }
                    .overlay { searchOverlay }
                    .navigationTitle(localOnly ? "Search This Server's Channels" : "Search Channels")
                    .searchable(text: $searchText, prompt: "Search channels…")
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
                    .navigationDestination(for: VideoChannel.self) { channel in
                        ChannelDetailView(handle: channel.handle)
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
            vm.configure(apiClient: session.apiClient, host: localOnly ? session.baseURL?.host : nil)
        }
    }

    @ViewBuilder
    private var searchOverlay: some View {
        if let error = vm.errorMessage, vm.results.isEmpty {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else if !vm.isLoading && vm.results.isEmpty && !vm.activeQuery.isEmpty {
            ContentUnavailableView(
                "No channels for \"\(vm.activeQuery)\"",
                systemImage: "magnifyingglass",
                description: Text("Try a different name.")
            )
        } else if vm.activeQuery.isEmpty && !vm.isLoading {
            VStack(spacing: 16) {
                Image(systemName: "person.2")
                    .font(.system(size: 60))
                    .foregroundStyle(.tertiary)
                Text(localOnly ? "Search channels hosted on this server" : "Search channels this server knows")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 80)
            }
        }
    }
}

private struct ChannelsTabRefreshTokenKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// Incremented in `MainTabView` when the Channels tab is selected or the app returns to the foreground on it.
    var peerTVChannelsTabRefreshToken: Int {
        get { self[ChannelsTabRefreshTokenKey.self] }
        set { self[ChannelsTabRefreshTokenKey.self] = newValue }
    }
}

struct ChannelCardView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.isFocused) private var isFocused
    let channel: VideoChannel

    var body: some View {
        VStack(spacing: 12) {
            ChannelAvatarView(
                url: session.thumbnailURL(
                    path: channel.avatars?.last?.resolvablePath
                          ?? channel.ownerAccount?.avatars?.last?.resolvablePath
                )
            )
            .frame(width: 120, height: 120)
            .scaleEffect(isFocused ? CardFocusStyle.parallaxImageScale : 1.0)
            .animation(CardFocusStyle.animation, value: isFocused)

            Text(channel.displayName ?? channel.name ?? "Channel")
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)

            if let followers = channel.followersCount {
                Text("\(followers) followers")
                    .font(.caption)
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .animation(CardFocusStyle.animation, value: isFocused)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .modifier(FocusedCardEffect(isFocused: isFocused))
    }
}
