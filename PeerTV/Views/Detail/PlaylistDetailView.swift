import SwiftUI

struct PlaylistDetailView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var playlistEditCoordinator: PlaylistEditCoordinator
    @StateObject private var vm: PlaylistDetailViewModel
    @State private var detailVideoId: String = ""
    @State private var showDetail = false
    @State private var didLongPress = false
    @State private var isEditingPlaylist = false
    @State private var elementPendingRemoval: PlaylistElement?
    @State private var actionMenuElement: PlaylistElement?
    @State private var reposition: RepositionState?
    @FocusState private var repositionFocusedRowID: String?
    @FocusState private var playlistPlayFocusVideoId: String?
    @State private var playlistGridLayoutWidth: CGFloat = 0
    @State private var playlistAutoplayEnabled: Bool
    @State private var lastPlayedVideoId: String?
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var allVideoIds: [String]?
    @State private var showDownloadQualityPicker = false
    @State private var showRemoveDownloadsConfirm = false

    private struct RepositionState {
        let movedElementId: Int
        let originalStartPosition: Int
        let originalIndex: Int
        var draft: [PlaylistElement]
    }

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    init(playlistId: Int) {
        _vm = StateObject(wrappedValue: PlaylistDetailViewModel(playlistId: playlistId))
        let key = Self.playlistAutoplayDefaultsKey(playlistId: playlistId)
        let initialAutoplay: Bool
        if UserDefaults.standard.object(forKey: key) == nil {
            initialAutoplay = true
        } else {
            initialAutoplay = UserDefaults.standard.bool(forKey: key)
        }
        _playlistAutoplayEnabled = State(initialValue: initialAutoplay)
    }

    private static func playlistAutoplayDefaultsKey(playlistId: Int) -> String {
        "PeerTV.playlistAutoplay.\(playlistId)"
    }

    private func playlistCellScrollId(videoId: String) -> String {
        "playlistCell-\(videoId)"
    }

    private var orderedPlaylistVideoIds: [String] {
        vm.elements.compactMap { $0.video?.stableId }
    }

    private var hasAnyUndownloaded: Bool {
        guard let ids = allVideoIds else { return false }
        return ids.contains { !downloadManager.isDownloaded($0) }
    }

    private var allDownloaded: Bool {
        guard let ids = allVideoIds, !ids.isEmpty else { return false }
        return ids.allSatisfy { downloadManager.isDownloaded($0) }
    }

    private var gridElements: [PlaylistElement] {
        if let r = reposition { return r.draft }
        return vm.elements
    }

    private var showActionMenu: Binding<Bool> {
        Binding(
            get: { actionMenuElement != nil },
            set: { if !$0 { actionMenuElement = nil } }
        )
    }

    /// Drives layout animation while reordering (order of stable row ids).
    private var repositionOrderAnimationKey: String {
        guard let r = reposition else { return "" }
        return r.draft.map(\.stableRowID).joined(separator: "|")
    }

    /// Matches `LazyVGrid` adaptive columns: minimum 380pt + 30pt spacing (see `columns`).
    private var estimatedPlaylistColumnCount: Int {
        let spacing: CGFloat = 30
        let minCell: CGFloat = 380
        let w = playlistGridLayoutWidth > 1 ? playlistGridLayoutWidth : 1600
        let slot = minCell + spacing
        return max(1, Int((w + spacing) / slot))
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
            if vm.isLoading && vm.playlist == nil {
                ProgressView()
                    .padding(.top, 200)
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    if let playlist = vm.playlist {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: 35) {
                                Text(playlist.displayName ?? "Playlist")
                                    .font(.title3)
                                    .bold()

                                if session.tokenStore.accessToken != nil, reposition == nil {
                                    Button {
                                        if isEditingPlaylist {
                                            cancelReposition()
                                            isEditingPlaylist = false
                                        } else {
                                            isEditingPlaylist = true
                                        }
                                    } label: {
                                        HStack(spacing: 20) {
                                            Image(systemName: isEditingPlaylist ? "checkmark.circle" : "square.and.pencil")
                                            Text(isEditingPlaylist ? "Done" : "Edit")
                                        }
                                        .font(.callout)
                                        .padding(.horizontal, 48)
                                        .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.card)
                                }

                                Button {
                                    playlistAutoplayEnabled.toggle()
                                } label: {
                                    HStack(spacing: 20) {
                                        Image(systemName: playlistAutoplayEnabled ? "repeat.circle.fill" : "repeat.circle")
                                        Text("Autoplay")
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 48)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.card)
                                .accessibilityValue(playlistAutoplayEnabled ? "On" : "Off")

                                if let batch = downloadManager.batchProgress, batch.playlistId == vm.playlistId {
                                    Button {
                                        downloadManager.cancelPlaylistBatch()
                                    } label: {
                                        HStack(spacing: 16) {
                                            ProgressView(value: Double(batch.completed), total: Double(max(batch.total, 1)))
                                                .progressViewStyle(.linear)
                                                .frame(width: 120)
                                            Text("\(batch.completed)/\(batch.total)")
                                                .monospacedDigit()
                                            Image(systemName: "xmark.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .font(.callout)
                                        .padding(.horizontal, 48)
                                        .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.card)
                                } else {
                                    if hasAnyUndownloaded {
                                        Button {
                                            showDownloadQualityPicker = true
                                        } label: {
                                            HStack(spacing: 20) {
                                                Image(systemName: "arrow.down.circle")
                                                Text("Download all")
                                            }
                                            .font(.callout)
                                            .padding(.horizontal, 48)
                                            .padding(.vertical, 12)
                                        }
                                        .buttonStyle(.card)
                                    }

                                    if allDownloaded {
                                        Button {
                                            showRemoveDownloadsConfirm = true
                                        } label: {
                                            HStack(spacing: 20) {
                                                Image(systemName: "trash")
                                                Text("Remove downloads")
                                            }
                                            .font(.callout)
                                            .padding(.horizontal, 48)
                                            .padding(.vertical, 12)
                                        }
                                        .buttonStyle(.card)
                                    }
                                }
                            }

                            if let desc = playlist.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            if let count = playlist.videosLength {
                                Text("\(count) videos")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.top, 40)
                    }

                    if isEditingPlaylist, session.tokenStore.accessToken != nil {
                        if reposition != nil {
                            Text("Use the arrow buttons to move the video. Press the select button to save. Press Menu to cancel.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 60)
                        } else {
                            Text("Click a video to remove it from the playlist or reposition it.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 60)
                        }
                    }

                    LazyVGrid(columns: columns, spacing: 50) {
                        ForEach(gridElements, id: \.stableRowID) { element in
                            if let video = element.video {
                                Group {
                                    if reposition != nil {
                                        let isGrabbed = element.id == reposition?.movedElementId
                                        if isGrabbed {
                                            Button {
                                                Task { await commitReposition() }
                                            } label: {
                                                VideoCardView(video: video)
                                                    .scaleEffect(1.05)
                                                    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                                                    .overlay {
                                                        RoundedRectangle(cornerRadius: 12)
                                                            .strokeBorder(.primary.opacity(0.55), lineWidth: 3)
                                                    }
                                            }
                                            .buttonStyle(.card)
                                            .focused($repositionFocusedRowID, equals: element.stableRowID)
                                            .zIndex(1)
                                            .onMoveCommand(perform: handleRepositionMoveCommand)
                                        } else {
                                            VideoCardView(video: video)
                                                .focusable(false)
                                        }
                                    } else if isEditingPlaylist {
                                        Button {
                                            actionMenuElement = element
                                        } label: {
                                            VideoCardView(video: video)
                                        }
                                        .buttonStyle(.card)
                                    } else {
                                        Button {
                                            if didLongPress { didLongPress = false; return }
                                            let ids = orderedPlaylistVideoIds
                                            if let idx = ids.firstIndex(of: video.stableId) {
                                                let queue = PlaylistPlaybackQueue(
                                                    videoIds: ids,
                                                    currentIndex: idx,
                                                    autoplayEnabled: playlistAutoplayEnabled,
                                                    apiClient: session.apiClient,
                                                    accessToken: session.tokenStore.accessToken
                                                )
                                                PlayerPresenter.shared.play(
                                                    videoId: video.stableId,
                                                    apiClient: session.apiClient,
                                                    accessToken: session.tokenStore.accessToken,
                                                    playlistQueue: queue
                                                )
                                            } else {
                                                PlayerPresenter.shared.play(
                                                    videoId: video.stableId,
                                                    apiClient: session.apiClient,
                                                    accessToken: session.tokenStore.accessToken
                                                )
                                            }
                                        } label: {
                                            VideoCardView(video: video)
                                        }
                                        .buttonStyle(.card)
                                        .focused($playlistPlayFocusVideoId, equals: video.stableId)
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.5)
                                                .onEnded { _ in
                                                    didLongPress = true
                                                    detailVideoId = video.stableId
                                                    showDetail = true
                                                }
                                        )
                                    }
                                }
                                .id(playlistCellScrollId(videoId: video.stableId))
                                .onAppear {
                                    guard reposition == nil else { return }
                                    guard !isEditingPlaylist else { return }
                                    if element.id == vm.elements.last?.id {
                                        Task { await vm.loadMore() }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 60)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: PlaylistGridLayoutWidthKey.self,
                                value: geo.size.width
                            )
                        }
                    }
                    .onPreferenceChange(PlaylistGridLayoutWidthKey.self) { playlistGridLayoutWidth = $0 }
                    .animation(
                        reposition == nil ? nil : .spring(response: 0.48, dampingFraction: 0.82),
                        value: repositionOrderAnimationKey
                    )
                }
            }
            }
            .onReceive(NotificationCenter.default.publisher(for: .peerTVPlaylistNowPlayingVideoId)) { note in
                guard let id = note.userInfo?["videoId"] as? String else { return }
                lastPlayedVideoId = id
                guard !isEditingPlaylist, reposition == nil else { return }
                playlistPlayFocusVideoId = id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(playlistCellScrollId(videoId: id), anchor: .center)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .peerTVPlayerDismissed)) { note in
                guard let id = note.userInfo?["videoId"] as? String else { return }
                lastPlayedVideoId = id
                guard !isEditingPlaylist, reposition == nil else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    playlistPlayFocusVideoId = id
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(playlistCellScrollId(videoId: id), anchor: .center)
                    }
                }
            }
        }
        .overlay {
            if let error = vm.errorMessage, vm.elements.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            VideoDetailView(videoId: detailVideoId)
        }
        .modifier(RepositionMenuExitModifier(isActive: reposition != nil, onMenu: { cancelReposition() }))
        .confirmationDialog(
            actionMenuTitle,
            isPresented: showActionMenu,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let e = actionMenuElement { elementPendingRemoval = e }
                actionMenuElement = nil
            }
            .disabled(actionMenuElement?.id == nil)

            Button("Reposition") {
                if let e = actionMenuElement { beginReposition(e) }
                actionMenuElement = nil
            }
            .disabled(actionMenuElement?.id == nil || actionMenuElement?.position == nil)

            Button("Cancel", role: .cancel) {
                actionMenuElement = nil
            }
        } message: {
            Text("Choose an action for this video.")
        }
        .alert("Remove from playlist?", isPresented: removalAlertBinding) {
            Button("Remove", role: .destructive) {
                if let e = elementPendingRemoval {
                    Task {
                        await vm.removePlaylistElement(e)
                        elementPendingRemoval = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                elementPendingRemoval = nil
            }
        } message: {
            Text("This video will be removed from this playlist only.")
        }
        .onDisappear {
            playlistEditCoordinator.isRepositioning = false
        }
        .onChange(of: playlistAutoplayEnabled) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: Self.playlistAutoplayDefaultsKey(playlistId: vm.playlistId))
        }
        .confirmationDialog("Download Quality", isPresented: $showDownloadQualityPicker, titleVisibility: .visible) {
            ForEach(DownloadQualityPreference.allCases) { pref in
                Button(pref.label) {
                    Task {
                        var ids = allVideoIds
                        if ids == nil {
                            ids = await vm.loadAllPlaylistVideoIds()
                            allVideoIds = ids
                        }
                        guard let ids else { return }
                        downloadManager.startPlaylistBatch(
                            playlistId: vm.playlistId,
                            videoIds: ids,
                            preference: pref,
                            accessToken: session.tokenStore.accessToken,
                            apiClient: session.apiClient
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove all downloads for this playlist?", isPresented: $showRemoveDownloadsConfirm, titleVisibility: .visible) {
            Button("Remove downloads", role: .destructive) {
                if let ids = allVideoIds {
                    downloadManager.removeDownloads(forVideoIds: Set(ids))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            vm.configure(apiClient: session.apiClient)
            await vm.loadInitial()
            allVideoIds = await vm.loadAllPlaylistVideoIds()
        }
    }

    private var actionMenuTitle: String {
        if let name = actionMenuElement?.video?.name, !name.isEmpty { return name }
        return "Video"
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding(
            get: { elementPendingRemoval != nil },
            set: { if !$0 { elementPendingRemoval = nil } }
        )
    }

    private func beginReposition(_ element: PlaylistElement) {
        guard let id = element.id, let pos = element.position,
              let idx = vm.elements.firstIndex(where: { $0.id == id }) else { return }
        let rowID = element.stableRowID
        reposition = RepositionState(
            movedElementId: id,
            originalStartPosition: pos,
            originalIndex: idx,
            draft: vm.elements
        )
        playlistEditCoordinator.isRepositioning = true
        DispatchQueue.main.async {
            repositionFocusedRowID = rowID
        }
    }

    private func cancelReposition() {
        repositionFocusedRowID = nil
        reposition = nil
        playlistEditCoordinator.isRepositioning = false
    }

    private func handleRepositionMoveCommand(_ direction: MoveCommandDirection) {
        guard let r = reposition,
              let idx = r.draft.firstIndex(where: { $0.id == r.movedElementId }) else { return }
        let cols = estimatedPlaylistColumnCount
        switch direction {
        case .left:
            moveMoveredItemToIndex(idx - 1, animated: true)
        case .right:
            moveMoveredItemToIndex(idx + 1, animated: true)
        case .up:
            moveMoveredItemToIndex(idx - cols, animated: true)
        case .down:
            moveMoveredItemToIndex(idx + cols, animated: true)
        @unknown default:
            break
        }
    }

    /// Moves the grabbed playlist element to a target index in the draft (0 … count-1).
    private func moveMoveredItemToIndex(_ targetIndex: Int, animated: Bool) {
        guard var r = reposition,
              let from = r.draft.firstIndex(where: { $0.id == r.movedElementId }) else { return }
        let n = r.draft.count
        guard n > 0 else { return }
        let t = max(0, min(n - 1, targetIndex))
        if from == t { return }
        var a = r.draft
        let item = a.remove(at: from)
        let insertAt = min(t, a.count)
        a.insert(item, at: insertAt)
        r.draft = a
        applyRepositionDraft(r, animated: animated)
    }

    private func applyRepositionDraft(_ state: RepositionState, animated: Bool) {
        if animated {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
                reposition = state
            }
        } else {
            reposition = state
        }
    }

    private func commitReposition() async {
        guard let r = reposition else { return }
        await vm.commitDraftReorder(
            movedElementId: r.movedElementId,
            originalStartPosition: r.originalStartPosition,
            originalIndex: r.originalIndex,
            draft: r.draft
        )
        if vm.errorMessage == nil {
            cancelReposition()
        }
    }
}

private struct RepositionMenuExitModifier: ViewModifier {
    let isActive: Bool
    let onMenu: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            content.onExitCommand(perform: onMenu)
        } else {
            content
        }
    }
}

private struct PlaylistGridLayoutWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
