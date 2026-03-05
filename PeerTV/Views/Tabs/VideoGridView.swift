import SwiftUI

struct VideoGridView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = HomeViewModel()
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var showSearch = false
    @State private var didLongPress = false

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Text("Trending")
                        .font(.title3)
                        .bold()

                    Button {
                        showSearch = true
                    } label: {
                        HStack(spacing: 20) {
                            Image(systemName: "magnifyingglass")
                            Text("Search")
                        }
                        .font(.callout)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.card)
                }
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
                ProgressView()
                    .padding()
            }
        }
        .overlay {
            if let error = vm.errorMessage, vm.videos.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(videoId: detailVideoId)
        }
        .navigationDestination(isPresented: $showSearch) {
            SearchView()
        }
        .task {
            vm.configure(apiClient: session.apiClient, isAuthenticated: session.phase == .authenticated)
            await vm.loadInitial()
        }
    }
}

// MARK: - Video Card

struct VideoCardView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.isFocused) var isFocused
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 16:9 thumbnail
            ZStack(alignment: .bottomTrailing) {
                Color.gray.opacity(0.15)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: session.thumbnailURL(path: video.thumbnailPath))
                    }
                    .clipped()

                if !video.formattedDuration.isEmpty {
                    Text(video.formattedDuration)
                        .font(.caption2)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.8))
                        .cornerRadius(4)
                        .padding(8)
                }
            }
            .cornerRadius(10)

            // Avatar + metadata
            HStack(alignment: .top, spacing: 12) {
                ChannelAvatarView(
                    url: session.thumbnailURL(
                        path: video.channel?.avatars?.first?.path
                              ?? video.account?.avatars?.first?.path
                    )
                )
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(video.name ?? "Untitled", isActive: isFocused)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Text(video.channel?.displayName ?? video.account?.displayName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    metadataLine
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .frame(height: 120, alignment: .top)
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 0) {
            if let date = video.relativeDate {
                Text(date)
            }
            if video.relativeDate != nil, video.views != nil {
                Text(" · ")
            }
            if let views = video.views {
                Text("\(views) views")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Marquee Text

/// Shows text in up to 2 lines when idle. When `isActive` (card focused),
/// switches to a single line and auto-scrolls horizontally if the text overflows.
struct MarqueeText: View {
    let text: String
    let isActive: Bool

    @State private var scrollOffset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    init(_ text: String, isActive: Bool) {
        self.text = text
        self.isActive = isActive
    }

    var body: some View {
        // Hidden layout reference — always 2 lines, sets the tile width.
        Text(text)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay(alignment: .topLeading) {
                // Visible text: 2 lines normally, single-line marquee when focused.
                Text(text)
                    .lineLimit(isActive ? 1 : 2)
                    .fixedSize(horizontal: isActive, vertical: false)
                    .offset(x: scrollOffset)
            }
            .clipped()
            .background(GeometryReader { g in
                Color.clear.preference(key: MarqueeContainerWidthKey.self, value: g.size.width)
            })
            .background(
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear.preference(key: MarqueeTextWidthKey.self, value: g.size.width)
                    })
                    .hidden()
            )
            .onPreferenceChange(MarqueeTextWidthKey.self) { textWidth = $0 }
            .onPreferenceChange(MarqueeContainerWidthKey.self) { containerWidth = $0 }
            .onChange(of: isActive) { _, active in
                if active {
                    scrollOffset = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard self.overflow > 0 else { return }
                        let duration = max(0.25, Double(self.overflow) / 210.0)
                        withAnimation(.linear(duration: duration).delay(0.8)) {
                            scrollOffset = -self.overflow
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) {
                        scrollOffset = 0
                    }
                }
            }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarqueeContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Channel Avatar

/// Circular avatar with a person.circle.fill SF Symbol fallback.
struct ChannelAvatarView: View {
    let url: URL?

    var body: some View {
        if url != nil {
            CachedAsyncImage(
                url: url,
                placeholder: AnyView(fallbackIcon)
            )
            .clipShape(Circle())
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.gray)
            .background(Circle().fill(Color(.darkGray)))
            .clipShape(Circle())
    }
}
