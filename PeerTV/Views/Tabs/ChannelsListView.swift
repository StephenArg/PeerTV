import SwiftUI

struct ChannelsListView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.peerTVChannelsTabRefreshToken) private var channelsTabRefreshToken
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
            await vm.loadInitialIfEmpty()
        }
        .onChange(of: channelsTabRefreshToken) { _, _ in
            vm.configure(apiClient: session.apiClient)
            Task { await vm.refreshInPlace() }
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
