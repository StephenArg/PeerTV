import SwiftUI

struct VideoGridView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = HomeViewModel()
    @State private var detailVideoId: String = ""
    @State private var detailOriginHost: String?
    @State private var detailCommentReadHost: String?
    @State private var showDetail = false
    @State private var showSearch = false
    @State private var showSortDialog = false
    @State private var showScopeDialog = false
    @State private var showFediverseLanguagePicker = false
    @State private var didLongPress = false
    /// False when another tab is selected so we do not scroll/focus the home grid when the player dismisses from elsewhere.
    @State private var isHomeGridOnScreen = false
    @FocusState private var homeGridFocusVideoId: String?

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    private func homeCellScrollId(videoId: String) -> String {
        "homeCell-\(videoId)"
    }

    private var isFediverseTrending: Bool {
        vm.currentListScope == .fediverseTrending
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .center, spacing: 28) {
                        Text(isFediverseTrending ? "Trending on Fediverse" : vm.currentListSort.displayName)
                            .font(.title3)
                            .bold()
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(0)

                        HStack(spacing: 35) {
                            Button {
                                showSearch = true
                            } label: {
                                HStack(spacing: 20) {
                                    Image(systemName: "magnifyingglass")
                                    Text("Search")
                                        .lineLimit(1)
                                }
                                .font(.callout)
                                .padding(.horizontal, 48)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.card)

                            if !session.isAnonymous, vm.showsSortControls {
                                Button {
                                    showSortDialog = true
                                } label: {
                                    HStack(spacing: 20) {
                                        Image(systemName: "arrow.up.arrow.down.circle")
                                        Text("Sort")
                                            .lineLimit(1)
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 48)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.card)
                            }

                            if !session.isAnonymous {
                                Button {
                                    showScopeDialog = true
                                } label: {
                                    HStack(spacing: 20) {
                                        Image(systemName: "globe")
                                        Text("Platforms")
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.72)
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 48)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.card)
                            }

                            if isFediverseTrending {
                                Button {
                                    showFediverseLanguagePicker = true
                                } label: {
                                    HStack(spacing: 20) {
                                        Image(systemName: "character.bubble")
                                        Text(vm.fediverseLanguageButtonTitle)
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
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    }
                    .padding(.horizontal, 50)

                    LazyVGrid(columns: columns, spacing: 50) {
                        ForEach(vm.videos, id: \.stableId) { video in
                            Button {
                                if didLongPress { didLongPress = false; return }
                                let tileThumb = VideoTileImageURL.thumbnail(
                                    for: video,
                                    session: session,
                                    federatedDisplay: isFediverseTrending
                                )
                                let tileAvatar = VideoTileImageURL.channelAvatar(
                                    for: video,
                                    session: session,
                                    federatedDisplay: isFediverseTrending
                                )
                                if isFediverseTrending {
                                    let hosts = video.federatedAPIHosts
                                    guard let firstHost = hosts.first else { return }
                                    PlayerPresenter.shared.play(
                                        videoId: video.stableId,
                                        apiClient: PeerTubeOriginClients.publicClient(forHost: firstHost),
                                        accessToken: nil,
                                        apiHosts: hosts,
                                        accountId: session.playbackAccountId,
                                        historyTileThumbnailURL: tileThumb,
                                        historyTileChannelAvatarURL: tileAvatar
                                    )
                                } else {
                                    PlayerPresenter.shared.play(
                                        videoId: video.stableId,
                                        apiClient: session.apiClient,
                                        accessToken: session.tokenStore.accessToken,
                                        accountId: session.playbackAccountId,
                                        historyTileThumbnailURL: tileThumb,
                                        historyTileChannelAvatarURL: tileAvatar
                                    )
                                }
                            } label: {
                                VideoCardView(
                                    video: video,
                                    showOriginHost: isFediverseTrending
                                )
                            }
                            .buttonStyle(.card)
                            .focused($homeGridFocusVideoId, equals: video.stableId)
                            .id(homeCellScrollId(videoId: video.stableId))
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .onEnded { _ in
                                        didLongPress = true
                                        detailVideoId = video.stableId
                                        detailOriginHost = isFediverseTrending ? video.originHost : nil
                                        detailCommentReadHost = isFediverseTrending ? video.commentReadHost : nil
                                        showDetail = true
                                    }
                            )
                            .onAppear {
                                if isFediverseTrending {
                                    Task { await vm.enrichFediverseRow(for: video.stableId) }
                                }
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
            .onReceive(NotificationCenter.default.publisher(for: .peerTVPlayerDismissed)) { note in
                guard isHomeGridOnScreen else { return }
                guard let id = note.userInfo?["videoId"] as? String else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    homeGridFocusVideoId = id
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(homeCellScrollId(videoId: id), anchor: .center)
                    }
                }
            }
        }
        .overlay {
            if let error = vm.errorMessage, vm.videos.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(
                videoId: detailVideoId,
                originHost: detailOriginHost,
                commentReadHost: detailCommentReadHost
            )
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView()
                .environmentObject(session)
                .presentationBackground(.black)
        }
        .sheet(isPresented: $showFediverseLanguagePicker) {
            FediverseLanguagePickerView(initialSelection: Set(vm.fediverseLanguageIds)) { selection in
                Task { await vm.applyFediverseLanguages(selection) }
            }
        }
        .confirmationDialog(
            "Sort by",
            isPresented: $showSortDialog,
            titleVisibility: .visible
        ) {
            ForEach(HomeVideoListSort.dialogOrder) { option in
                Button(option == vm.currentListSort ? "\(option.displayName) ✓" : option.displayName) {
                    Task { await vm.applyListSort(option) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Show videos from",
            isPresented: $showScopeDialog,
            titleVisibility: .visible
        ) {
            ForEach(HomeVideoScope.dialogOrder) { option in
                Button(option == vm.currentListScope ? "\(option.displayName) ✓" : option.displayName) {
                    Task { await vm.applyListScope(option) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { isHomeGridOnScreen = true }
        .onDisappear { isHomeGridOnScreen = false }
        .task {
            vm.configure(
                apiClient: session.apiClient,
                isAuthenticated: session.phase == .authenticated,
                includeAllPrivacy: session.useBroadHomeVideoListing
            )
            if session.isAnonymous {
                await vm.loadAnonymousFediverseHome()
            } else {
                await vm.loadInitialIfEmpty()
            }
        }
        .onChange(of: session.isAnonymous) { _, anonymous in
            guard anonymous else { return }
            Task { await vm.loadAnonymousFediverseHome() }
        }
        .onChange(of: session.useBroadHomeVideoListing) { _, _ in
            guard !session.isAnonymous else { return }
            vm.configure(
                apiClient: session.apiClient,
                isAuthenticated: session.phase == .authenticated,
                includeAllPrivacy: session.useBroadHomeVideoListing
            )
            Task { await vm.loadInitial() }
        }
    }
}

// MARK: - Card Focus Style

enum CardFocusStyle {
    static let scale: CGFloat = 1.06
    static let parallaxImageScale: CGFloat = 1.08
    static let shadowColor = Color.black.opacity(0.55)
    static let shadowRadius: CGFloat = 28
    static let shadowY: CGFloat = 14
    static let ringWidth: CGFloat = 3
    static let thumbnailCornerRadius: CGFloat = 10
    static let animation: Animation = .easeOut(duration: 0.18)
}

struct FocusedCardEffect: ViewModifier {
    let isFocused: Bool
    var scaleAnchor: UnitPoint = .center

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                isFocused ? CardFocusStyle.scale : 1.0,
                anchor: scaleAnchor
            )
            .shadow(
                color: isFocused ? CardFocusStyle.shadowColor : .clear,
                radius: isFocused ? CardFocusStyle.shadowRadius : 0,
                y: isFocused ? CardFocusStyle.shadowY : 0
            )
            .animation(CardFocusStyle.animation, value: isFocused)
    }
}

struct CardThumbnailFocusOverlay: View {
    let isFocused: Bool

    var body: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.45)],
            startPoint: .center,
            endPoint: .bottom
        )
        .opacity(isFocused ? 1 : 0)
        .animation(CardFocusStyle.animation, value: isFocused)
        .allowsHitTesting(false)
    }
}

// MARK: - Tile Preview (storyboard cycling on focus)

/// When the parent tile is focused (and the setting is enabled), cycles through the video's
/// storyboard sprite frames over its static thumbnail — the same frames shown when scrubbing.
private struct TilePreviewLayer: View {
    @EnvironmentObject var session: SessionStore
    let video: Video
    let isFocused: Bool
    let federatedDisplay: Bool
    /// Set true once the preview window finishes (or there's nothing to preview), so the
    /// parent can reveal the on-tile control hints.
    @Binding var showControls: Bool

    /// Seconds each preview frame is shown before advancing.
    private static let frameInterval: UInt64 = 900_000_000
    /// Delay before previewing starts, so quickly passing focus over a tile doesn't load it.
    private static let startDelay: UInt64 = 300_000_000
    /// How long to cycle before freezing back on the original thumbnail.
    private static let previewDuration: Double = 7

    @State private var frame: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let frame {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .allowsHitTesting(false)
            .task(id: isFocused) {
                frame = nil
                showControls = false
                guard isFocused else { return }
                if TilePreviewSettings.isEnabled {
                    await runPreview()
                } else {
                    try? await Task.sleep(nanoseconds: Self.startDelay)
                }
                guard !Task.isCancelled, isFocused else { return }
                withAnimation(.easeInOut(duration: 0.3)) { showControls = true }
            }
    }

    private func runPreview() async {
        try? await Task.sleep(nanoseconds: Self.startDelay)
        guard !Task.isCancelled else { return }

        guard let provider = await TileStoryboardLoader.shared.provider(
            for: video,
            instanceClient: session.apiClient,
            federatedDisplay: federatedDisplay
        ) else { return }
        guard !Task.isCancelled else { return }

        let step = Double(max(1, provider.storyboard.spriteDuration))
        let duration = Double(video.duration ?? 0)
        let span = duration > 0 ? duration : step * 20

        // Snap between sprite frames without animation. Animating the image swap makes
        // SwiftUI cross-fade the bitmap, which briefly reveals the static thumbnail
        // underneath (a visible flash) between frames.
        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true

        var time: Double = 0
        var elapsed: Double = 0
        while !Task.isCancelled, elapsed < Self.previewDuration {
            if let image = provider.image(for: time) {
                withTransaction(noAnimation) { frame = image }
            }
            try? await Task.sleep(nanoseconds: Self.frameInterval)
            elapsed += Double(Self.frameInterval) / 1_000_000_000
            time += step
            if time >= span { time = 0 }
        }

        // Preview window finished — freeze back on the original static thumbnail.
        if !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.25)) { frame = nil }
        }
    }
}

// MARK: - Preview Control Hints

/// On-tile hints shown at the bottom-left once the preview cycle finishes, telling the user
/// what the remote buttons do for the focused video.
private struct PreviewControlHints: View {
    var body: some View {
        HStack(spacing: 14) {
            hint(icon: "info.circle", text: "Hold for details")
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.6), in: Capsule())
        .allowsHitTesting(false)
    }

    private func hint(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
    }
}

// MARK: - Video Card

struct VideoCardView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.isFocused) var isFocused
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var showPreviewControls = false
    let video: Video
    var showOriginHost: Bool = false
    /// When set (e.g. anonymous history), use this URL directly instead of re-resolving paths.
    var thumbnailURLOverride: URL? = nil
    var avatarURLOverride: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 16:9 thumbnail
            ZStack(alignment: .bottomTrailing) {
                Color.gray.opacity(0.15)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        ZStack {
                            CachedAsyncImage(url: cardThumbnailURL(path: video.thumbnailPath))
                            TilePreviewLayer(
                                video: video,
                                isFocused: isFocused,
                                federatedDisplay: showOriginHost,
                                showControls: $showPreviewControls
                            )
                        }
                        .scaleEffect(isFocused ? CardFocusStyle.parallaxImageScale : 1.0)
                        .animation(CardFocusStyle.animation, value: isFocused)
                    }
                    .clipped()
                    .cornerRadius(CardFocusStyle.thumbnailCornerRadius)
                    .overlay {
                        CardThumbnailFocusOverlay(isFocused: isFocused)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if showPreviewControls {
                            PreviewControlHints()
                                .padding(8)
                                .transition(.opacity)
                        }
                    }

                if !video.formattedDuration.isEmpty {
                    Text(video.formattedDuration)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.black.opacity(0.85))
                        )
                        .drawingGroup()
                        .padding(8)
                }
            }
            .modifier(FocusedCardEffect(isFocused: isFocused, scaleAnchor: .bottom))

            // Avatar + metadata
            HStack(alignment: .top, spacing: 12) {
                ChannelAvatarView(url: cardAvatarURL())
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(video.name ?? "Untitled", isActive: isFocused)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    if showOriginHost, let host = video.originHost {
                        Text(channelLineWithHost(host))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(video.channel?.displayName ?? video.account?.displayName ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    metadataLine
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .frame(height: 120, alignment: .top)
        }
    }

    private func cardThumbnailURL(path: String?) -> URL? {
        VideoTileImageURL.thumbnail(
            for: video,
            session: session,
            federatedDisplay: showOriginHost,
            override: thumbnailURLOverride
        )
    }

    private func cardAvatarURL() -> URL? {
        VideoTileImageURL.channelAvatar(
            for: video,
            session: session,
            federatedDisplay: showOriginHost,
            override: avatarURLOverride
        )
    }

    private func channelLineWithHost(_ host: String) -> String {
        let name = video.channel?.displayName
            ?? video.channel?.name
            ?? video.account?.displayName
            ?? video.account?.name
            ?? "Unknown"
        return "\(name) · \(host)"
    }

    private var metadataLine: some View {
        let isDownloaded = downloadManager.isDownloaded(video.stableId)
        let hasViews = video.abbreviatedViewsLabel != nil
        let hasLeadingMetadata = video.relativeDate != nil || hasViews

        return HStack(spacing: 0) {
            if let date = video.relativeDate {
                Text(date)
            }
            if video.relativeDate != nil, hasViews {
                Text(" · ")
            }
            if let label = video.abbreviatedViewsLabel {
                Text(label)
            }
            if hasLeadingMetadata, isDownloaded {
                Text(" · ")
            }
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .accessibilityLabel("Downloaded")
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
