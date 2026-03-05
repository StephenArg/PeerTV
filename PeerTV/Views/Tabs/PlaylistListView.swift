import SwiftUI

struct PlaylistListView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = PlaylistsViewModel()

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Playlists")
                    .font(.title3)
                    .bold()
                    .padding(.horizontal, 50)

                LazyVGrid(columns: columns, spacing: 50) {
                    ForEach(vm.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistCardView(playlist: playlist)
                        }
                        .buttonStyle(.card)
                        .onAppear {
                            if playlist.id == vm.playlists.last?.id {
                                Task { await vm.loadMore() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 50)
            }
            .padding(.top, 40)
            .padding(.bottom, 50)

            if vm.isLoading {
                ProgressView().padding()
            }
        }
        .overlay {
            if let error = vm.errorMessage, vm.playlists.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .task {
            vm.configure(
                apiClient: session.apiClient,
                accountName: session.username.isEmpty ? nil : session.username
            )
            await vm.loadInitial()
        }
    }
}

struct PlaylistCardView: View {
    @EnvironmentObject var session: SessionStore
    let playlist: VideoPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Color.gray.opacity(0.15)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: session.thumbnailURL(path: playlist.thumbnailPath))
                    }
                    .clipped()
                    .cornerRadius(10)

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
