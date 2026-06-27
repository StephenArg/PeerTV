import SwiftUI

private enum PlaylistListGridRow: Identifiable {
    case playlist(VideoPlaylist)
    case add

    var id: String {
        switch self {
        case .playlist(let p):
            if let id = p.id { return "playlist-\(id)" }
            return "playlist-\(p.uuid ?? "unknown")"
        case .add:
            return "playlist-add-new"
        }
    }
}

struct PlaylistListView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.peerTVPlaylistsTabRefreshToken) private var playlistsTabRefreshToken
    @StateObject private var vm = PlaylistsViewModel()
    @State private var showNewPlaylistSheet = false

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    private var playlistGridRows: [PlaylistListGridRow] {
        let playlists = vm.playlists.map { PlaylistListGridRow.playlist($0) }
        // Omit the add tile while the first page is loading so it never appears alone at the
        // top-left and then jumps to the end when rows arrive (LazyVGrid reflow).
        if vm.isLoading && vm.playlists.isEmpty {
            return playlists
        }
        return playlists + [.add]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Playlists")
                    .font(.title3)
                    .bold()
                    .padding(.horizontal, 50)

                if vm.isLoading && vm.playlists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 50) {
                        ForEach(playlistGridRows) { row in
                            switch row {
                            case .playlist(let playlist):
                                NavigationLink(value: playlist) {
                                    PlaylistCardView(playlist: playlist)
                                }
                                .buttonStyle(.card)
                                .onAppear {
                                    if playlist.id == vm.playlists.last?.id {
                                        Task { await vm.loadMore() }
                                    }
                                }
                            case .add:
                                Button {
                                    showNewPlaylistSheet = true
                                } label: {
                                    AddPlaylistPlaceholderCardView()
                                }
                                .buttonStyle(.card)
                            }
                        }
                    }
                    .padding(.horizontal, 50)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 50)
        }
        .overlay {
            if let error = vm.errorMessage, vm.playlists.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            NewPlaylistNamePromptView(title: "New Playlist") { name in
                await vm.createPlaylist(named: name)
            }
        }
        .onAppear {
            Task { await refreshPlaylists() }
        }
        .onChange(of: playlistsTabRefreshToken) { _, _ in
            Task { await refreshPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .peerTVPlaylistsNeedRefresh)) { _ in
            Task { await refreshPlaylists() }
        }
    }

    private func refreshPlaylists() async {
        vm.configure(
            apiClient: session.apiClient,
            accountName: session.username.isEmpty ? nil : session.username
        )
        await vm.loadInitial()
    }
}

private struct PlaylistsTabRefreshTokenKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// Incremented in `MainTabView` whenever the Playlists tab is selected.
    var peerTVPlaylistsTabRefreshToken: Int {
        get { self[PlaylistsTabRefreshTokenKey.self] }
        set { self[PlaylistsTabRefreshTokenKey.self] = newValue }
    }
}

struct PlaylistCardView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.isFocused) private var isFocused
    let playlist: VideoPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Color.gray.opacity(0.15)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: session.thumbnailURL(path: playlist.thumbnailPath))
                            .scaleEffect(isFocused ? CardFocusStyle.parallaxImageScale : 1.0)
                            .animation(CardFocusStyle.animation, value: isFocused)
                    }
                    .clipped()
                    .cornerRadius(CardFocusStyle.thumbnailCornerRadius)
                    .overlay {
                        CardThumbnailFocusOverlay(isFocused: isFocused)
                    }

                if let count = playlist.videosLength {
                    HStack(spacing: 4) {
                        Image(systemName: "list.and.film")
                        Text("\(count)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.75))
                    .cornerRadius(6)
                    .padding(8)
                }
            }
            .modifier(FocusedCardEffect(isFocused: isFocused, scaleAnchor: .bottom))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.displayName ?? "Playlist")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Text(playlist.ownerAccount?.displayName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 14)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(height: 90, alignment: .top)
        }
    }
}

// MARK: - New playlist (shared with video detail picker)

struct NewPlaylistNamePromptView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onCreate: (String) async -> Result<Void, Error>
    var onOuterSuccess: (() -> Void)?

    @State private var name = ""
    @State private var inlineError: String?
    @FocusState private var nameFocused: Bool

    init(
        title: String,
        onCreate: @escaping (String) async -> Result<Void, Error>,
        onSuccess: (() -> Void)? = nil
    ) {
        self.title = title
        self.onCreate = onCreate
        self.onOuterSuccess = onSuccess
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Playlist name", text: $name)
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .focused($nameFocused)

                if let inlineError {
                    Text(inlineError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 420, minHeight: 220)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await attemptCreate() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            inlineError = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                nameFocused = true
            }
        }
    }

    private func attemptCreate() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inlineError = nil
        switch await onCreate(trimmed) {
        case .success:
            dismiss()
            onOuterSuccess?()
        case .failure(let error):
            inlineError = error.localizedDescription
        }
    }
}

private struct AddPlaylistPlaceholderCardView: View {
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Color.gray.opacity(0.15)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                            .scaleEffect(isFocused ? CardFocusStyle.parallaxImageScale : 1.0)
                            .animation(CardFocusStyle.animation, value: isFocused)
                    }
                    .clipped()
                    .cornerRadius(CardFocusStyle.thumbnailCornerRadius)
            }
            .modifier(FocusedCardEffect(isFocused: isFocused, scaleAnchor: .bottom))

            VStack(alignment: .leading, spacing: 4) {
                Text("New playlist")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Text(" ")
                    .font(.caption)
                    .foregroundStyle(.clear)
                    .lineLimit(1)
            }
            .padding(.top, 14)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(height: 90, alignment: .top)
        }
    }
}
