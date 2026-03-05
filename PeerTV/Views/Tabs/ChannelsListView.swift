import SwiftUI

struct ChannelsListView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = ChannelsViewModel()

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 40)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Channels")
                    .font(.title3)
                    .bold()
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
        .task {
            vm.configure(apiClient: session.apiClient)
            await vm.loadInitial()
        }
    }
}

struct ChannelCardView: View {
    @EnvironmentObject var session: SessionStore
    let channel: VideoChannel

    var body: some View {
        VStack(spacing: 12) {
            ChannelAvatarView(
                url: session.thumbnailURL(
                    path: channel.avatars?.last?.path
                          ?? channel.ownerAccount?.avatars?.last?.path
                )
            )
            .frame(width: 120, height: 120)

            Text(channel.displayName ?? channel.name ?? "Channel")
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)

            if let followers = channel.followersCount {
                Text("\(followers) followers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
