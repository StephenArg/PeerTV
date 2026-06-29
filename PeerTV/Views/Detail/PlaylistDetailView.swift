import SwiftUI

struct PlaylistDetailView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var playlistEditCoordinator: PlaylistEditCoordinator
    @Environment(\.dismiss) private var dismiss
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
    @State private var playlistShuffleEnabled = false
    /// Local shuffle order as `PlaylistElement.stableRowID`s; empty means no shuffle applied.
    @State private var shuffleOrder: [String] = []
    @State private var lastPlayedVideoId: String?
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var allVideoIds: [String]?
    @State private var showDownloadQualityPicker = false
    @State private var showRemoveDownloadsConfirm = false
    @State private var showDeletePlaylistConfirm = false
    @State private var playlistDeleteFailureMessage: String?
    @State private var showPlaylistPrivacyPicker = false
    @State private var showPublicChannelPicker = false
    @State private var playlistPrivacyFailureMessage: String?

    private struct RepositionState {
        let movedElementId: Int
        let originalStartPosition: Int
        let originalIndex: Int
        var draft: [PlaylistElement]
    }

    private let columns = [
        GridItem(.adaptive(minimum: 380, maximum: 480), spacing: 30)
    ]

    init(playlistId: Int, initialPlaylistPathId: String? = nil) {
        _vm = StateObject(wrappedValue: PlaylistDetailViewModel(playlistId: playlistId, initialPlaylistPathId: initialPlaylistPathId))
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
        if playlistShuffleEnabled, !isEditingPlaylist {
            return shuffledElements.compactMap { $0.video?.stableId }
        }
        return vm.elements.compactMap { $0.video?.stableId }
    }

    /// `vm.elements` reordered by `shuffleOrder`. Any elements not yet in the
    /// shuffle order (e.g. freshly paginated) are appended in their loaded order.
    private var shuffledElements: [PlaylistElement] {
        let byId = Dictionary(vm.elements.map { ($0.stableRowID, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [PlaylistElement] = []
        var seen = Set<String>()
        for rowID in shuffleOrder {
            if let element = byId[rowID] {
                result.append(element)
                seen.insert(rowID)
            }
        }
        for element in vm.elements where !seen.contains(element.stableRowID) {
            result.append(element)
        }
        return result
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
        if playlistShuffleEnabled, !isEditingPlaylist { return shuffledElements }
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

                                if reposition == nil {
                                    if isEditingPlaylist, session.tokenStore.accessToken != nil {
                                        Button {
                                            showPlaylistPrivacyPicker = true
                                        } label: {
                                            HStack(spacing: 20) {
                                                Image(systemName: "lock.square")
                                                Text("Privacy")
                                            }
                                            .font(.callout)
                                            .padding(.horizontal, 48)
                                            .padding(.vertical, 12)
                                        }
                                        .buttonStyle(.card)

                                        Button {
                                            showDeletePlaylistConfirm = true
                                        } label: {
                                            HStack(spacing: 20) {
                                                Image(systemName: "trash.circle")
                                                Text("Delete")
                                            }
                                            .font(.callout)
                                            .padding(.horizontal, 48)
                                            .padding(.vertical, 12)
                                        }
                                        .buttonStyle(.card)
                                    } else {
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

                                        if playlistAutoplayEnabled {
                                            Button {
                                                togglePlaylistShuffle()
                                            } label: {
                                                HStack(spacing: 20) {
                                                    Image(systemName: playlistShuffleEnabled ? "shuffle.circle.fill" : "shuffle.circle")
                                                    Text(playlistShuffleEnabled ? "Shuffle" : "In order")
                                                }
                                                .font(.callout)
                                                .padding(.horizontal, 48)
                                                .padding(.vertical, 12)
                                            }
                                            .buttonStyle(.card)
                                            .accessibilityValue(playlistShuffleEnabled ? "Shuffle" : "In order")
                                        }

                                        if let batch = downloadManager.batchProgress, batch.playlistId == vm.playlistId {
                                            Button {
                                                downloadManager.cancelPlaylistBatch()
                                            } label: {
                                                playlistBatchDownloadLabel(batch: batch)
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
                                                    accountId: session.activeAccountId,
                                                    playlistQueue: queue
                                                )
                                            } else {
                                                PlayerPresenter.shared.play(
                                                    videoId: video.stableId,
                                                    apiClient: session.apiClient,
                                                    accessToken: session.tokenStore.accessToken,
                                                    accountId: session.activeAccountId
                                                )
                                            }
                                        } label: {
                                            VideoCardView(video: video)
                                        }
                                        .buttonStyle(.card)
                                        .videoTilePlaylistPicker(video: video)
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
                                    if element.stableRowID == gridElements.last?.stableRowID {
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
            if !newValue {
                playlistShuffleEnabled = false
                shuffleOrder = []
            }
        }
        .onChange(of: vm.elements.count) { _, _ in
            guard playlistShuffleEnabled else { return }
            extendShuffleOrderWithNewElements()
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
        .confirmationDialog(
            "Delete this playlist?",
            isPresented: $showDeletePlaylistConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete playlist", role: .destructive) {
                Task {
                    if let batch = downloadManager.batchProgress, batch.playlistId == vm.playlistId {
                        downloadManager.cancelPlaylistBatch()
                    }
                    let ok = await vm.deletePlaylist()
                    if ok {
                        isEditingPlaylist = false
                        dismiss()
                    } else {
                        playlistDeleteFailureMessage = vm.errorMessage ?? "The playlist could not be deleted."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the playlist from your account. Downloaded video files are not deleted.")
        }
        .alert(
            "Could not delete playlist",
            isPresented: Binding(
                get: { playlistDeleteFailureMessage != nil },
                set: { if !$0 { playlistDeleteFailureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playlistDeleteFailureMessage ?? "")
        }
        .confirmationDialog("Playlist privacy", isPresented: $showPlaylistPrivacyPicker, titleVisibility: .visible) {
            ForEach(vm.playlistPrivacyMenuItems) { item in
                let currentId = vm.playlist?.privacy?.id
                let check = currentId == item.id ? " \u{2713}" : ""
                Button("\(item.label)\(check)") {
                    Task { await applyPlaylistPrivacyChoice(privacyId: item.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Options match your PeerTube server. “Internal” applies to videos, not playlists.")
        }
        .confirmationDialog("Channel for public playlist", isPresented: $showPublicChannelPicker, titleVisibility: .visible) {
            ForEach(Array(vm.accountChannels.enumerated()), id: \.offset) { _, channel in
                let title = Self.channelPickerTitle(channel)
                let existingId = vm.playlist?.videoChannel?.id
                let check = (existingId == channel.id) ? " \u{2713}" : ""
                Button("\(title)\(check)") {
                    Task {
                        guard let id = channel.id else { return }
                        let ok = await vm.updatePlaylistPrivacy(privacyId: 1, videoChannelId: id)
                        if !ok {
                            playlistPrivacyFailureMessage = vm.errorMessage ?? "Privacy could not be updated."
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pick which of your channels this playlist is published on.")
        }
        .alert(
            "Privacy",
            isPresented: Binding(
                get: { playlistPrivacyFailureMessage != nil },
                set: { if !$0 { playlistPrivacyFailureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playlistPrivacyFailureMessage ?? "")
        }
        .task {
            vm.configure(
                apiClient: session.apiClient,
                accountName: session.username.isEmpty ? nil : session.username
            )
            async let privacyMenu: () = vm.refreshPlaylistPrivacyMenuItems()
            await vm.loadInitial()
            await privacyMenu
            allVideoIds = await vm.loadAllPlaylistVideoIds()
        }
    }

    @ViewBuilder
    private func playlistBatchDownloadLabel(batch: DownloadManager.BatchProgress) -> some View {
        let fileProgress = batch.currentVideoId.flatMap { downloadManager.activeDownloads[$0] }

        HStack(spacing: 16) {
            Group {
                if let fileProgress, fileProgress.totalBytes > 0 {
                    ProgressView(value: fileProgress.fractionCompleted)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .frame(width: 120)

            Text("\(batch.completed) / \(batch.total) downloaded")
                .monospacedDigit()
                .lineLimit(1)

            if let fileProgress, fileProgress.totalBytes > 0 {
                Text("\(VideoDownloadBar.formatBytes(fileProgress.receivedBytes)) / \(VideoDownloadBar.formatBytes(fileProgress.totalBytes))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let fileProgress, fileProgress.bytesPerSecond > 0 {
                Text(VideoDownloadBar.formatSpeed(fileProgress.bytesPerSecond))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 48)
        .padding(.vertical, 12)
    }

    private static func channelPickerTitle(_ channel: VideoChannel) -> String {
        if let d = channel.displayName, !d.isEmpty { return d }
        if let n = channel.name, !n.isEmpty { return n }
        return "Channel"
    }

    @MainActor
    private func applyPlaylistPrivacyChoice(privacyId: Int) async {
        if privacyId == 1 {
            if vm.playlist?.videoChannel?.id != nil {
                let ok = await vm.updatePlaylistPrivacy(privacyId: 1, videoChannelId: nil)
                if !ok {
                    playlistPrivacyFailureMessage = vm.errorMessage ?? "Privacy could not be updated."
                }
            } else {
                await vm.loadAccountChannels()
                if vm.accountChannels.isEmpty {
                    playlistPrivacyFailureMessage = vm.errorMessage ?? "No channels found on your account. Create one on the PeerTube website."
                } else {
                    showPublicChannelPicker = true
                }
            }
        } else {
            let ok = await vm.updatePlaylistPrivacy(privacyId: privacyId, videoChannelId: nil)
            if !ok {
                playlistPrivacyFailureMessage = vm.errorMessage ?? "Privacy could not be updated."
            }
        }
    }

    /// Toggles between a local random order and the playlist's natural order.
    private func togglePlaylistShuffle() {
        playlistShuffleEnabled.toggle()
        if playlistShuffleEnabled {
            shuffleOrder = vm.elements.map { $0.stableRowID }.shuffled()
        } else {
            shuffleOrder = []
        }
    }

    /// Keeps `shuffleOrder` in sync as pagination loads more elements: drops any
    /// stale ids and appends newly loaded ones in a random position at the end.
    private func extendShuffleOrderWithNewElements() {
        let currentIds = vm.elements.map { $0.stableRowID }
        let currentSet = Set(currentIds)
        let existing = Set(shuffleOrder)
        let additions = currentIds.filter { !existing.contains($0) }.shuffled()
        guard !additions.isEmpty else { return }
        shuffleOrder = shuffleOrder.filter { currentSet.contains($0) } + additions
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
